defmodule Website45sV3.Game.GameEvents do
  @moduledoc """
  The per-game event log kept by `Website45sV3.Game.GameController` and
  persisted on `Website45sV3.Game.GameLog` when the game ends.

  The log is for analytics: every deal, bid, discard, card, trick and score,
  plus the things that hint at confusion (idle timeouts, players leaving and
  coming back, abandonment), each stamped with milliseconds since the game
  started and with whether a bot or a human acted.

  Events are flat maps with short keys so the JSON compresses well and stays
  easy to read for a person or a model:

      %{"t" => 4210, "e" => "bid", "p" => 2, "v" => 20, "s" => "hearts", "b" => false}

  Players are referred to by seat index (0..3, queue join order) and cards by
  `Card.encode/1` strings such as `"10_hearts"`. The whole log is gzipped
  JSON; `decode/1` reverses `finalize/2`.
  """

  alias Website45sV3.Game.Card

  @format_version 1

  @doc """
  The state keys the log needs: an empty event list and the start clock.
  """
  def init do
    %{
      events: [],
      started_at: System.monotonic_time(:millisecond),
      started_at_utc: DateTime.utc_now()
    }
  end

  @doc """
  Prepends an event to the game state's log. `attrs` must be JSON-safe.
  """
  def log(state, type, attrs \\ %{}) do
    event =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"t" => elapsed_ms(state), "e" => type})

    %{state | events: [event | state.events]}
  end

  @doc """
  The seat index of a player id, the way players are named in the log.
  """
  def seat(state, player_id), do: Enum.find_index(state.player_ids, &(&1 == player_id))

  @doc """
  Every seat's hand as encoded card lists, in seat order.
  """
  def hands(state) do
    Enum.map(state.player_ids, fn id -> cards(Map.get(state.hands, id, [])) end)
  end

  def cards(cards), do: Enum.map(cards, &Card.encode/1)

  @doc """
  The `GameLog` attributes for a game that has ended: the summary columns and
  the gzipped JSON log. `reason` is `:normal` or `{:error, reason}`.
  """
  def finalize(state, reason) do
    events = Enum.reverse(state.events)
    winner = winner(state)

    document = %{
      "v" => @format_version,
      "game" => state.game_name,
      "started_at" => DateTime.to_iso8601(state.started_at_utc),
      "players" =>
        Enum.with_index(state.player_ids, fn id, seat ->
          %{
            "seat" => seat,
            "name" => Map.get(state.player_map, id, "Anonymous"),
            "bot" => MapSet.member?(state.seat_bots, id)
          }
        end),
      "ended" => ended(state, reason),
      "winner" => winner,
      "events" => events
    }

    %{
      game_name: state.game_name,
      ended: ended(state, reason),
      duration_ms: elapsed_ms(state),
      hands: length(state.team_1_history),
      human_count: length(state.player_ids) - MapSet.size(state.seat_bots),
      winner: winner,
      team1_score: state.team_scores.team1,
      team2_score: state.team_scores.team2,
      event_count: length(events),
      events: :zlib.gzip(Jason.encode!(document))
    }
  end

  @doc """
  Decodes a log produced by `finalize/2`.
  """
  def decode(nil), do: {:error, :no_events}

  def decode(binary) when is_binary(binary) do
    Jason.decode(:zlib.gunzip(binary))
  rescue
    ErlangError -> {:error, :corrupt}
  end

  defp ended(_state, {:error, _}), do: "crash"
  defp ended(%{phase: "Final Scoring"}, _reason), do: "finished"
  defp ended(_state, _reason), do: "abandoned"

  # The game decides the winner (`Rules.score_round/4`: when both teams
  # cross the line in one hand the bidders win, whatever the scores say),
  # so the log reports what it decided rather than re-deriving it.
  defp winner(%{phase: "Final Scoring"} = state) do
    case Map.get(state, :winning_team) do
      team when team in [:team1, :team2] -> Atom.to_string(team)
      _ -> nil
    end
  end

  defp winner(_state), do: nil

  defp elapsed_ms(state), do: System.monotonic_time(:millisecond) - state.started_at
end
