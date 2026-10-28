defmodule Website45sV3.Game.QueueHolders do
  @moduledoc """
  Which processes are keeping a player in a queue, for `QueueStarter` and
  `PrivateQueueManager`.

  Each process that adds a player (a lobby LiveView, a bot) is monitored and
  holds that player's place. A player leaves the queue once no process holds
  them any more: the last tab said so (`release/3`), or every holding process
  exited. The second case is the one that matters. A LiveView is not
  guaranteed to run `terminate/2`; navigating from the lobby to another page
  in the same live_session reuses the channel topic, and Phoenix kills the old
  LiveView with an exit signal it does not trap. Before this, such a player
  stayed queued and was later seated in a game they never saw.

  `key` is whatever identifies a queued player to the caller: the player id
  for the public queue, `{lobby_id, player_id}` for a private lobby.

  `on_drop` is an optional zero-arity function the queue runs (in a separate
  process) when the player is dropped because their holders exited, so the
  departure is still recorded.
  """

  @type t :: %{pid() => %{key: term(), ref: reference(), on_drop: (-> any()) | nil}}

  def new, do: %{}

  @doc """
  Records that `pid` holds `key`. A pid already holding it keeps its monitor;
  its `on_drop` is replaced when a new one is given.
  """
  def hold(holders, pid, key, on_drop \\ nil) do
    case holders do
      %{^pid => %{key: ^key} = entry} ->
        Map.put(holders, pid, %{entry | on_drop: on_drop || entry.on_drop})

      %{^pid => %{ref: ref}} ->
        # One process holds one place; joining elsewhere moves it.
        Process.demonitor(ref, [:flush])
        Map.put(holders, pid, %{key: key, ref: Process.monitor(pid), on_drop: on_drop})

      _ ->
        Map.put(holders, pid, %{key: key, ref: Process.monitor(pid), on_drop: on_drop})
    end
  end

  @doc """
  `pid` stops holding `key`. Returns the remaining holders.
  """
  def release(holders, pid, key) do
    case holders do
      %{^pid => %{key: ^key, ref: ref}} ->
        Process.demonitor(ref, [:flush])
        Map.delete(holders, pid)

      _ ->
        holders
    end
  end

  @doc """
  Whether any process still holds `key`.
  """
  def held?(holders, key), do: Enum.any?(holders, fn {_pid, entry} -> entry.key == key end)

  @doc """
  Drops the holder whose monitor fired. Returns `{entry | nil, holders}`.
  """
  def down(holders, pid, ref) do
    case holders do
      %{^pid => %{ref: ^ref} = entry} -> {entry, Map.delete(holders, pid)}
      _ -> {nil, holders}
    end
  end

  @doc """
  Forgets every holder whose key `keep?` rejects (players matched into a
  game, removed, or in a lobby that closed).
  """
  def prune(holders, keep?) do
    {kept, dropped} = Map.split_with(holders, fn {_pid, entry} -> keep?.(entry.key) end)
    Enum.each(dropped, fn {_pid, entry} -> Process.demonitor(entry.ref, [:flush]) end)
    kept
  end

  @doc """
  Runs a dropped holder's `on_drop` without blocking the queue process.
  """
  def notify_drop(%{on_drop: on_drop}) when is_function(on_drop, 0) do
    Task.start(on_drop)
  end

  def notify_drop(_entry), do: :ok

  @doc """
  A short, log-friendly form of a player id: bots are "bot", sessions show
  their first 8 characters (enough to find them in `site_events`).
  """
  def short_id("bot_" <> _), do: "bot"
  def short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  def short_id(other), do: inspect(other)
end
