defmodule Website45sV3.Game.QueueStarter do
  @moduledoc """
  Manages a queue of players waiting to start a game in the Website45sV3 application.

  This module uses a GenServer to maintain the state of the player queue and handle requests to add or remove players. When enough players are in the queue, a new game is started.

  ## Key Functions

    - `start_link/1`: Starts the GenServer with an initial state.
    - `add_player/1`: Adds a player to the queue.
    - `remove_player/1`: Removes a player from the queue.

  ## GenServer Callbacks

    - `init/1`: Initializes the GenServer state.
    - `handle_call/3`: Handles synchronous calls to the GenServer.

  ## Private Functions

    - `start_game/1`: Starts a new game with the first four players in the queue.
    - `wait_for_registration/2`: Waits for the game to be registered in the system.
    - `game_registered?/1`: Checks if the game is registered.
    - `create_unique_game_name/0`: Creates a unique name for the game.
    - `generate_game_name/0`: Generates a random game name.
  """
  use GenServer

  # API
  def start_link(initial_state \\ []) do
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def add_player({display_name, unique_identifier}) do
    GenServer.call(__MODULE__, {:add_player, {display_name, unique_identifier}})
  end

  def remove_player({display_name, unique_identifier}) do
    GenServer.call(__MODULE__, {:remove_player, {display_name, unique_identifier}})
  end

  # GenServer callbacks
  def init(state) do
    {:ok, state}
  end

  def handle_call({:add_player, player_name}, _from, state) do
    updated_state = state ++ [player_name]

    if length(updated_state) >= 4 do
      players = Enum.take(updated_state, 4)
      start_game(players)
      {:reply, :ok, Enum.drop(updated_state, 4)}
    else
      {:reply, :ok, updated_state}
    end
  end

  def handle_call({:remove_player, player_tuple}, _from, state) do
    updated_state = Enum.reject(state, fn player -> player == player_tuple end)
    {:reply, :ok, updated_state}
  end

  defp start_game(players) do
    game_name = create_unique_game_name()

    Website45sV3.Game.GameController.start_game(game_name, players)
    wait_for_registration(game_name)

    # Redirect the players to the game page
    for {_display_name, unique_identifier} <- players do
      Phoenix.PubSub.broadcast(
        Website45sV3.PubSub,
        "user:#{unique_identifier}",
        {:redirect, "/game/#{game_name}"}
      )
    end
  end

  defp wait_for_registration(game_name, retries \\ 10) do
    if !game_registered?(game_name) && retries > 0 do
      :timer.sleep(500)
      wait_for_registration(game_name, retries - 1)
    end
  end

  defp game_registered?(game_name) do
    case Registry.lookup(Website45sV3.Registry, game_name) do
      [] -> false
      [_ | _] -> true
    end
  end

  defp create_unique_game_name do
    game_name = generate_game_name()

    case Registry.lookup(Website45sV3.Registry, game_name) do
      [] -> game_name
      _other -> create_unique_game_name()
    end
  end

  defp generate_game_name do
    # Using :rand.uniform/1 to get an integer value between 1 and the maximum allowed value.
    random_number = <<:rand.uniform(:erlang.system_info(:wordsize) * 8 - 1)::integer>>

    :crypto.hash(:sha256, random_number)
    |> Base.encode16()
    |> String.slice(0, 12)
  end
end
