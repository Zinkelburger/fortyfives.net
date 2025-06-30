defmodule Website45sV3.Game.PrivateQueueManager do
  use GenServer

  # Client API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{queues: %{}, last_created: %{}}, name: __MODULE__)
  end

  def create_queue(id, owner_id) do
    GenServer.call(__MODULE__, {:create_queue, id, owner_id})
  end

  def add_player(id, {name, user_id}) do
    GenServer.call(__MODULE__, {:add_player, id, {name, user_id}})
  end

  def remove_player(id, user_id) do
    GenServer.call(__MODULE__, {:remove_player, id, user_id})
  end

  def queue_players(id) do
    GenServer.call(__MODULE__, {:queue_players, id})
  end

  # Server callbacks
  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:create_queue, id, owner_id}, _from, state) do
    now = System.system_time(:second)
    last = Map.get(state.last_created, owner_id, 0)

    if now - last < 120 do
      {:reply, {:error, :too_soon}, state}
    else
      queues = Map.put_new(state.queues, id, %{players: [], owner: owner_id})
      last_created = Map.put(state.last_created, owner_id, now)
      {:reply, :ok, %{state | queues: queues, last_created: last_created}}
    end
  end

  def handle_call({:add_player, id, {incoming_name, user_id}}, _from, state) do
    queue = Map.get(state.queues, id, %{players: []})
    players = queue.players

    if Enum.any?(players, fn {_n, id2} -> id2 == user_id end) do
      {:reply, :ok, state}
    else
      assigned_name =
        if String.trim(incoming_name) == "" or String.trim(incoming_name) == "Anonymous" do
          assign_anonymous_name(players)
        else
          incoming_name
        end

      updated_players = players ++ [{assigned_name, user_id}]
      state = put_in(state.queues[id], %{queue | players: updated_players})

      if length(updated_players) >= 4 do
        start_game(updated_players)
        new_state = %{state | queues: Map.delete(state.queues, id)}
        {:reply, :ok, new_state}
      else
        {:reply, :ok, state}
      end
    end
  end

  def handle_call({:remove_player, id, user_id}, _from, state) do
    queue = Map.get(state.queues, id, %{players: []})
    updated_players = Enum.reject(queue.players, fn {_n, id2} -> id2 == user_id end)
    state = put_in(state.queues[id], %{queue | players: updated_players})
    {:reply, :ok, state}
  end

  def handle_call({:queue_players, id}, _from, state) do
    players = get_in(state.queues, [id, :players]) || []
    {:reply, players, state}
  end

  defp assign_anonymous_name(players) do
    anonymous_numbers =
      players
      |> Enum.flat_map(fn {name, _id} ->
        case Regex.run(~r/^Anonymous(\d+)$/, name) do
          [_, num] -> [String.to_integer(num)]
          _ -> []
        end
      end)

    next_anonymous_number =
      case anonymous_numbers do
        [] -> 1
        _ -> Enum.max(anonymous_numbers) + 1
      end

    "Anonymous#{next_anonymous_number}"
  end

  defp start_game(players) do
    game_name = create_unique_game_name()
    Website45sV3.Game.GameController.start_game(game_name, players)
    wait_for_registration(game_name)

    for {_name, user_id} <- players do
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
      _ -> create_unique_game_name()
    end
  end

  defp generate_game_name do
    random_number = <<:rand.uniform(:erlang.system_info(:wordsize) * 8 - 1)::integer>>
    :crypto.hash(:sha256, random_number)
    |> Base.encode16()
    |> String.slice(0, 12)
  end
end
