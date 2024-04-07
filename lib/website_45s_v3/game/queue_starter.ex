defmodule Website45sV3.Game.QueueStarter do
  use GenServer

  # API
  def start_link(initial_state \\ []) do
    GenServer.start_link(__MODULE__, initial_state, name: __MODULE__)
  end

  def add_player({player_name, player_id}) do
    IO.puts("Player joined: #{player_name} (ID: #{player_id})")
    GenServer.call(__MODULE__, {:add_player, {player_name, player_id}})
  end

  def remove_player({player_name, player_id}) do
    IO.puts("Player left: #{player_name} (ID: #{player_id})")
    GenServer.call(__MODULE__, {:remove_player, {player_name, player_id}})
  end

  # GenServer callbacks
  def init(state) do
    {:ok, state}
  end

  def handle_call({:add_player, player}, _from, state) do
    IO.puts("Before join: (state: #{state})")
    updated_state = state ++ [player]

    if length(updated_state) >= 4 do
      players = Enum.take(updated_state, 4)
      start_game(players)
      {:reply, :ok, Enum.drop(updated_state, 4)}
    else
      {:reply, :ok, updated_state}
    end
  end

  def handle_call({:remove_player, player}, _from, state) do
    IO.puts("Before leave: (state: #{state})")
    updated_state = List.delete(state, player)
    {:reply, :ok, updated_state}
  end

  defp start_game(players) do
    game_name = create_unique_game_name()

    Website45sV3.Game.GameController.start_game(game_name, players)
    wait_for_registration(game_name)

    # Redirect the players to the game page
    for {_display_name, user_id} <- players do
      Phoenix.PubSub.broadcast(
        Website45sV3.PubSub,
        "user:#{user_id}",
        {:redirect, "/game/#{game_name}"}
      )
    end
  end

  defp wait_for_registration(game_name, retries \\ 10) do
    if !is_game_registered?(game_name) && retries > 0 do
      :timer.sleep(500)
      wait_for_registration(game_name, retries - 1)
    end
  end

  defp is_game_registered?(game_name) do
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
