defmodule Website45sV3.Game.QueueStarter do
  use GenServer
  require Logger

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.Matchmaking

  # API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{players: []}, name: __MODULE__)
  end

  @doc """
  Adds a player to the queue. Returns `:ok`, or `{:error, :already_in_game}`
  when the player is still seated in a running game — one game per session.
  """
  def add_player({player_name, player_id}) do
    GenServer.call(__MODULE__, {:add_player, {player_name, player_id}})
  end

  def remove_player({_player_name, player_id}) do
    GenServer.call(__MODULE__, {:remove_player, player_id})
  end

  def player_count do
    GenServer.call(__MODULE__, :player_count)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_call(
        {:add_player, {incoming_player_name, player_id}},
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

      true ->
        assigned_player_name = Matchmaking.assign_display_name(incoming_player_name, players)
        Logger.info("Player joined queue: #{assigned_player_name} (ID: #{player_id})")

        updated_players = players ++ [{assigned_player_name, player_id}]

        if length(updated_players) >= 4 do
          {game_players, remaining} = Enum.split(updated_players, 4)

          case Matchmaking.start_game(game_players) do
            :ok ->
              {:reply, :ok, %{state | players: remaining}}

            {:error, _reason} ->
              # Keep everyone queued; the next join will retry.
              {:reply, :ok, %{state | players: updated_players}}
          end
        else
          {:reply, :ok, %{state | players: updated_players}}
        end
    end
  end

  def handle_call(:player_count, _from, %{players: players} = state) do
    {:reply, length(players), state}
  end

  def handle_call({:remove_player, player_id}, _from, %{players: players} = state) do
    Logger.info("Player left queue (ID: #{player_id})")
    updated_players = Enum.reject(players, fn {_username, id} -> id == player_id end)
    {:reply, :ok, %{state | players: updated_players}}
  end
end
