defmodule Website45sV3.Analytics do
  @moduledoc """
  Gameplay analytics: browser session replays and retention of both replays
  and the per-game event logs on `game_logs`.

  Recording is client-side (rrweb, see `assets/js/app.js`): the game page
  ships batches of events over its LiveView socket and this module stores
  each batch gzipped as a `ReplayChunk`, plus the clicks in it as
  `ReplayClick` rows on the server's clock so a game's timeline never has to
  decode a recording. Nothing here sees IP addresses or accounts; a replay
  is tied to a game name and the anonymous seat id.

  Retention is driven by the `Website45sV3.Analytics` application env:

    * `:record_replays` - master switch for browser recording (default true)
    * `:replay_days` - delete replays older than this (default 60)
    * `:replay_max_bytes` - keep total compressed replay storage under this
      by deleting the oldest replays first (default 2 GB)
    * `:game_events_days` - null `game_logs.events` older than this; the
      summary row is kept forever (default 365)

  `Website45sV3.Analytics.Pruner` applies these once a day.
  """

  import Ecto.Query

  alias Website45sV3.Analytics.Replay
  alias Website45sV3.Analytics.ReplayChunk
  alias Website45sV3.Analytics.ReplayClick
  alias Website45sV3.Game.GameLog
  alias Website45sV3.Repo

  # Caps on what one browser may send, to keep a misbehaving (or hostile)
  # client from filling the disk: one batch, one whole recording, and the
  # clicks reported with one batch.
  @max_chunk_bytes 1_000_000
  @max_replay_bytes 25_000_000
  @max_clicks_per_chunk 500

  # What a reported click may carry (see SessionRecorder.logClick in
  # assets/js/app.js); anything else is dropped, strings are cut short.
  @click_strings ~w(el phx card text phase)
  @click_flags ~w(dead turn auto)
  @click_string_max 120

  @defaults [
    record_replays: true,
    replay_days: 60,
    replay_max_bytes: 2_000_000_000,
    game_events_days: 365
  ]

  def config(key) do
    :website_45s_v3
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc """
  Whether game pages should record. Read once per mount, so flipping the
  config affects new games only.
  """
  def record_replays?, do: config(:record_replays) == true

  ## Recording

  @doc """
  Opens a recording for one seat at one table.
  """
  def start_replay(attrs) do
    %Replay{}
    |> Replay.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Puts the clicks a browser reports with a batch onto the server's clock.

  `clicks` are the maps the SessionRecorder hook sends, each with `"ts"`,
  the browser's `Date.now()` at the click; `client_now` is the browser's
  `Date.now()` when it sent the batch. The difference between that and
  `server_now` is the browser's clock skew (plus a little network delay),
  and shifting every click by it lets the admin timeline line clicks up with
  game events even when the phone's clock is minutes off.

  Unknown keys and oversize strings are dropped, as is anything past the
  per-batch cap. Returns `%{at_ms: epoch_ms, data: click}` maps ready for
  `append_chunk/4`; garbage in, empty list out.
  """
  def clicks_from_client(clicks, client_now, server_now \\ System.os_time(:millisecond))

  def clicks_from_client(clicks, client_now, server_now)
      when is_list(clicks) and is_integer(client_now) do
    offset = server_now - client_now

    clicks
    |> Enum.take(@max_clicks_per_chunk)
    |> Enum.flat_map(fn
      %{"ts" => ts} = click when is_integer(ts) ->
        [%{at_ms: ts + offset, data: sanitize_click(click)}]

      _ ->
        []
    end)
  end

  def clicks_from_client(_clicks, _client_now, _server_now), do: []

  defp sanitize_click(click) do
    click
    |> Enum.filter(fn
      {key, value} when key in @click_strings -> is_binary(value)
      {key, value} when key in @click_flags -> is_boolean(value)
      _ -> false
    end)
    |> Map.new(fn
      {key, value} when is_binary(value) -> {key, String.slice(value, 0, @click_string_max)}
      pair -> pair
    end)
  end

  @doc """
  Stores one batch of rrweb events (`json`, a JSON array as sent by the
  client) as chunk `seq` of the replay, with the `clicks` reported alongside
  it (see `clicks_from_client/3`).

  Batches beyond the size caps, replayed sequence numbers, and batches for a
  replay that has since been pruned are refused with `{:error, reason}`.
  Never raises for a well-formed call; the game view relies on that.
  """
  def append_chunk(replay, seq, json, clicks \\ [])

  def append_chunk(%Replay{} = replay, seq, json, clicks)
      when is_integer(seq) and seq >= 0 and is_binary(json) and is_list(clicks) do
    data = :zlib.gzip(json)
    size = byte_size(data)

    cond do
      byte_size(json) > @max_chunk_bytes ->
        {:error, :chunk_too_large}

      replay.bytes + size > @max_replay_bytes ->
        {:error, :replay_too_large}

      true ->
        Repo.transaction(fn -> insert_chunk(replay, seq, data, clicks) end)
    end
  end

  def append_chunk(_replay, _seq, _json, _clicks), do: {:error, :invalid}

  defp insert_chunk(replay, seq, data, clicks) do
    %ReplayChunk{replay_id: replay.id, seq: seq, data: data}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:replay_id, :seq])
    |> Ecto.Changeset.foreign_key_constraint(:replay_id)
    |> Repo.insert()
    |> case do
      {:ok, _chunk} ->
        insert_clicks(replay, clicks)

        {1, [updated]} =
          Repo.update_all(
            from(r in Replay, where: r.id == ^replay.id, select: r),
            inc: [bytes: byte_size(data), chunk_count: 1],
            set: [updated_at: DateTime.utc_now(:second)]
          )

        updated

      {:error, changeset} ->
        Repo.rollback(rejection(changeset))
    end
  end

  defp insert_clicks(_replay, []), do: :ok

  defp insert_clicks(replay, clicks) do
    rows = Enum.map(clicks, &Map.put(&1, :replay_id, replay.id))
    Repo.insert_all(ReplayClick, rows)
    :ok
  end

  # The replay row is gone when the pruner removed it mid-game (it deletes
  # the oldest recordings first, and a long game's can be the oldest); the
  # only other constraint on a chunk is its sequence number.
  defp rejection(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :foreign end),
      do: :replay_gone,
      else: :duplicate_seq
  end

  ## Reading

  def get_replay!(id), do: Repo.get!(Replay, id)

  def list_replays(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Replay
    |> maybe_filter_game(Keyword.get(opts, :game_name))
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_game(query, nil), do: query
  defp maybe_filter_game(query, game_name), do: where(query, game_name: ^game_name)

  @doc """
  Every click recorded at a table, oldest first, as
  `{display_name, click, epoch_ms}` on the server's clock. A query over the
  click rows only; no recording is decoded.
  """
  def list_clicks(nil), do: []

  def list_clicks(game_name) do
    from(c in ReplayClick,
      join: r in assoc(c, :replay),
      where: r.game_name == ^game_name,
      order_by: [asc: c.at_ms, asc: c.id],
      select: {r.display_name, c.data, c.at_ms}
    )
    |> Repo.all()
    |> Enum.map(fn {name, click, at_ms} -> {name || "Anonymous", click, at_ms} end)
  end

  @doc """
  The whole recording as one JSON array string, ready for rrweb-player.
  Chunks are concatenated without decoding them.
  """
  def replay_events_json(%Replay{id: id}) do
    inner =
      from(c in ReplayChunk, where: c.replay_id == ^id, order_by: c.seq, select: c.data)
      |> Repo.all()
      |> Enum.map(&:zlib.gunzip/1)
      |> Enum.map(&strip_brackets/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(",")

    "[" <> inner <> "]"
  end

  defp strip_brackets(json) do
    json
    |> String.trim()
    |> String.replace_prefix("[", "")
    |> String.replace_suffix("]", "")
    |> String.trim()
  end

  @doc """
  Total compressed bytes held in replays.
  """
  def replay_bytes do
    # sum() over a bigint comes back as a Decimal.
    Repo.one(from(r in Replay, select: type(coalesce(sum(r.bytes), 0), :integer)))
  end

  ## Game logs

  def list_game_logs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(g in GameLog,
      order_by: [desc: g.inserted_at],
      limit: ^limit,
      select: %{g | events: nil}
    )
    |> Repo.all()
  end

  def get_game_log!(id), do: Repo.get!(GameLog, id)

  def get_game_log_by_name(nil), do: nil

  def get_game_log_by_name(game_name) do
    from(g in GameLog, where: g.game_name == ^game_name, order_by: [desc: g.id], limit: 1)
    |> Repo.one()
  end

  ## Retention

  @doc """
  Applies the retention config. Returns counts of what was removed.
  """
  def prune(now \\ DateTime.utc_now()) do
    %{
      replays_expired: prune_expired_replays(now),
      replays_over_cap: prune_replays_over_cap(),
      game_events_expired: prune_game_events(now)
    }
  end

  defp prune_expired_replays(now) do
    cutoff = DateTime.add(now, -config(:replay_days), :day)
    {count, _} = Repo.delete_all(from(r in Replay, where: r.inserted_at < ^cutoff))
    count
  end

  # Oldest first until the total is back under the cap. Replays are small
  # and few, so walking them in memory is fine.
  defp prune_replays_over_cap do
    over = replay_bytes() - config(:replay_max_bytes)

    case oldest_replays_totalling(over) do
      [] -> 0
      ids -> from(r in Replay, where: r.id in ^ids) |> Repo.delete_all() |> elem(0)
    end
  end

  defp oldest_replays_totalling(bytes) when bytes <= 0, do: []

  defp oldest_replays_totalling(bytes) do
    from(r in Replay, order_by: [asc: r.inserted_at, asc: r.id], select: {r.id, r.bytes})
    |> Repo.all()
    |> Enum.reduce_while({bytes, []}, fn {id, size}, {remaining, ids} ->
      if remaining > 0,
        do: {:cont, {remaining - size, [id | ids]}},
        else: {:halt, {remaining, ids}}
    end)
    |> elem(1)
  end

  defp prune_game_events(now) do
    cutoff = DateTime.add(now, -config(:game_events_days), :day)

    {count, _} =
      Repo.update_all(
        from(g in GameLog, where: g.inserted_at < ^cutoff and not is_nil(g.events)),
        set: [events: nil]
      )

    count
  end
end
