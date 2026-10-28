defmodule Website45sV3.Game.QueueStarter do
  @moduledoc """
  The public matchmaking queue. Players are seated in join order and a game
  starts as soon as four are waiting.

  The process that adds a player (their lobby LiveView, or a bot) holds the
  place; once every such process has released it or exited, the player is
  out (see `QueueHolders`). So closing or navigating away from the lobby
  always leaves the queue, even when the LiveView is killed without running
  `terminate/2`.
  """
  use GenServer
  require Logger

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.Matchmaking
  alias Website45sV3.Game.QueueHolders
  alias Website45sV3.Security.RateLimiter

  # API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{players: [], holders: QueueHolders.new()},
      name: __MODULE__
    )
  end

  @doc """
  Adds a player to the queue, held by the calling process. Returns `:ok`, or
  `{:error, :already_in_game}` when the player is still seated in a running
  game — one game per session.

  Options: `on_drop:` — run if the player is dropped because every process
  holding them exited (see `QueueHolders`).
  """
  def add_player({player_name, player_id}, remote_ip \\ nil, opts \\ []) do
    GenServer.call(__MODULE__, {:add_player, {player_name, player_id}, remote_ip, opts})
  end

  @doc """
  Removes a player outright, whoever holds them. Returns `:not_queued` after
  a match or an earlier removal.
  """
  def remove_player({_player_name, player_id}) do
    GenServer.call(__MODULE__, {:remove_player, player_id})
  end

  @doc """
  The calling process stops holding the player's place. The player leaves
  the queue (`:ok`) unless another of their tabs still holds it
  (`:held_elsewhere`); `:not_queued` after a match or an earlier removal.
  """
  def release_player(player_id) do
    GenServer.call(__MODULE__, {:release_player, player_id})
  end

  def player_count do
    GenServer.call(__MODULE__, :player_count)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(
        {:add_player, {incoming_player_name, player_id}, remote_ip, opts},
        {caller, _tag},
        %{players: players} = state
      ) do
    cond do
      queued?(players, player_id) ->
        # Already queued (e.g. the same session joined from a second tab).
        # Adding them twice would start a broken game with a duplicate seat;
        # the new tab holds the place too.
        holders = QueueHolders.hold(state.holders, caller, player_id, opts[:on_drop])
        {:reply, :ok, %{state | holders: holders}}

      ActiveGames.find_game(player_id) != nil ->
        # One game per session: they should rejoin (or abandon) that game
        # instead of accumulating a second one.
        {:reply, {:error, :already_in_game}, state}

      not queue_admission_allowed?(remote_ip) ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        assigned_player_name = Matchmaking.assign_display_name(incoming_player_name, players)
        updated_players = players ++ [{assigned_player_name, player_id}]

        Logger.info(
          "Queue: #{QueueHolders.short_id(player_id)} joined (#{length(updated_players)} waiting)"
        )

        holders = QueueHolders.hold(state.holders, caller, player_id, opts[:on_drop])
        {:reply, :ok, settle(%{state | holders: holders}, maybe_start_game(updated_players))}
    end
  end

  def handle_call(:player_count, _from, %{players: players} = state) do
    {:reply, length(players), state}
  end

  def handle_call({:remove_player, player_id}, _from, state) do
    {result, state} = remove(state, player_id, "left")
    {:reply, result, state}
  end

  def handle_call({:release_player, player_id}, {caller, _tag}, state) do
    holders = QueueHolders.release(state.holders, caller, player_id)
    state = %{state | holders: holders}

    cond do
      not queued?(state.players, player_id) ->
        {:reply, :not_queued, state}

      QueueHolders.held?(holders, player_id) ->
        {:reply, :held_elsewhere, state}

      true ->
        {result, state} = remove(state, player_id, "left")
        {:reply, result, state}
    end
  end

  # A process holding a place exited. If it was the last one holding that
  # player, they are gone: drop them before a game seats them.
  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {entry, holders} = QueueHolders.down(state.holders, pid, ref)
    state = %{state | holders: holders}

    if entry && queued?(state.players, entry.key) && not QueueHolders.held?(holders, entry.key) do
      {_result, state} = remove(state, entry.key, "dropped: its page closed without leaving")
      QueueHolders.notify_drop(entry)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp remove(state, player_id, how) do
    updated_players = Enum.reject(state.players, fn {_name, id} -> id == player_id end)

    if updated_players == state.players do
      {:not_queued, state}
    else
      Logger.info(
        "Queue: #{QueueHolders.short_id(player_id)} #{how} (#{length(updated_players)} waiting)"
      )

      {:ok, settle(state, updated_players)}
    end
  end

  # Stores the queue and forgets the holders of anyone no longer in it.
  defp settle(state, players) do
    ids = MapSet.new(players, fn {_name, id} -> id end)
    %{state | players: players, holders: QueueHolders.prune(state.holders, &(&1 in ids))}
  end

  defp queued?(players, player_id), do: Enum.any?(players, fn {_name, id} -> id == player_id end)

  # Starts a game with the first four players once enough are waiting and
  # returns the players still queued. If the game could not start everyone
  # stays queued; the next join retries.
  defp maybe_start_game(players) when length(players) < 4, do: players

  defp maybe_start_game(players) do
    {game_players, remaining} = Enum.split(players, 4)

    case Matchmaking.start_game(game_players, queue: "public") do
      :ok -> remaining
      {:error, _reason} -> players
    end
  end

  defp queue_admission_allowed?(nil), do: true
  defp queue_admission_allowed?(remote_ip), do: RateLimiter.check_queue_join(remote_ip) == :ok
end
