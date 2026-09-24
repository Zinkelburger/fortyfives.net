defmodule Website45sV3.Game.QueueStarter do
  @moduledoc """
  The public matchmaking queue. Players are seated in join order and a game
  starts as soon as four are waiting.
  """
  use GenServer
  require Logger

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.Matchmaking
  alias Website45sV3.Security.RateLimiter

  # API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{players: []}, name: __MODULE__)
  end

  @doc """
  Adds a player to the queue. Returns `:ok`, or `{:error, :already_in_game}`
  when the player is still seated in a running game — one game per session.
  """
  def add_player({player_name, player_id}, remote_ip \\ nil) do
    GenServer.call(__MODULE__, {:add_player, {player_name, player_id}, remote_ip})
  end

  # Returns :not_queued after a match or an earlier removal.
  def remove_player({_player_name, player_id}) do
    GenServer.call(__MODULE__, {:remove_player, player_id})
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
        {:add_player, {incoming_player_name, player_id}, remote_ip},
        _from,
        %{players: players} = state
      ) do
    cond do
      Enum.any?(players, fn {_name, id} -> id == player_id end) ->
        # Already queued (e.g. the same session joined from a second tab).
        # Adding them twice would start a broken game with a duplicate seat.
        {:reply, :ok, state}

      ActiveGames.find_game(player_id) != nil ->
        # One game per session: they should rejoin (or abandon) that game
        # instead of accumulating a second one.
        {:reply, {:error, :already_in_game}, state}

      not queue_admission_allowed?(remote_ip) ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        assigned_player_name = Matchmaking.assign_display_name(incoming_player_name, players)
        Logger.info("Player joined matchmaking queue")

        updated_players = players ++ [{assigned_player_name, player_id}]
        {:reply, :ok, %{state | players: maybe_start_game(updated_players)}}
    end
  end

  def handle_call(:player_count, _from, %{players: players} = state) do
    {:reply, length(players), state}
  end

  def handle_call({:remove_player, player_id}, _from, %{players: players} = state) do
    Logger.info("Player left matchmaking queue")
    updated_players = Enum.reject(players, fn {_username, id} -> id == player_id end)
    result = if updated_players == players, do: :not_queued, else: :ok
    {:reply, result, %{state | players: updated_players}}
  end

  # Starts a game with the first four players once enough are waiting and
  # returns the players still queued. If the game could not start everyone
  # stays queued; the next join retries.
  defp maybe_start_game(players) when length(players) < 4, do: players

  defp maybe_start_game(players) do
    {game_players, remaining} = Enum.split(players, 4)

    case Matchmaking.start_game(game_players) do
      :ok -> remaining
      {:error, _reason} -> players
    end
  end

  defp queue_admission_allowed?(nil), do: true
  defp queue_admission_allowed?(remote_ip), do: RateLimiter.check_queue_join(remote_ip) == :ok
end
