defmodule Website45sV3.Game.QueueStarter do
  use GenServer

  # API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{players: []}, name: __MODULE__)
  end

  def add_player({player_name, player_id}) do
    IO.puts("Player joined: #{player_name} (ID: #{player_id})")
    GenServer.call(__MODULE__, {:add_player, {player_name, player_id}})
  end

  def remove_player({player_name, player_id}) do
    IO.puts("Player left: #{player_name} (ID: #{player_id})")
    GenServer.call(__MODULE__, {:remove_player, player_id})
  end

  def init(state) do
    {:ok, state}
  end

  def handle_call({:add_player, {incoming_player_name, player_id}}, _from, %{players: players} = state) do
    assigned_player_name =
      if String.trim(incoming_player_name) == "" or String.trim(incoming_player_name) == "Anonymous" do
        assign_anonymous_name(players)
      else
        incoming_player_name
      end

    updated_state = %{state | players: players ++ [{assigned_player_name, player_id}]}

    if length(updated_state.players) >= 4 do
      players = Enum.take(updated_state.players, 4)
      start_game(players)
      {:reply, :ok, %{updated_state | players: Enum.drop(updated_state.players, 4)}}
    else
      {:reply, :ok, updated_state}
    end
  end

  def handle_call({:remove_player, player_id}, _from, %{players: players} = state) do
    IO.puts("Before leave: (state: #{inspect(state)})")
    updated_players = Enum.reject(players, fn {_username, id} -> id == player_id end)
    updated_state = %{state | players: updated_players}
    IO.puts("After leave: (state: #{inspect(updated_state)})")
    {:reply, :ok, updated_state}
  end

  defp assign_anonymous_name(players) do
    IO.inspect(players, label: "Players")
    anonymous_players =
      players
      |> Enum.filter(fn {name, _id} -> String.starts_with?(name, "Anonymous") end)

    IO.inspect(anonymous_players, label: "Anonymous Players")
    anonymous_numbers =
      anonymous_players
      |> Enum.map(fn {name, _id} ->
        case String.replace_prefix(name, "Anonymous", "") do
          "" -> 1
          num -> String.to_integer(num)
        end
      end)

    IO.inspect(anonymous_numbers, label: "Anonymous Numbers")

    next_anonymous_number =
      case anonymous_numbers do
        [] -> 1
        _ -> Enum.max(anonymous_numbers) + 1
      end

    IO.inspect(next_anonymous_number, label: "Next Anonymous Number")

    "Anonymous#{next_anonymous_number}"
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
    # Hash a random number, take first 12 chars as the game url
    random_number = <<:rand.uniform(:erlang.system_info(:wordsize) * 8 - 1)::integer>>

    :crypto.hash(:sha256, random_number)
    |> Base.encode16()
    |> String.slice(0, 12)
  end
end
