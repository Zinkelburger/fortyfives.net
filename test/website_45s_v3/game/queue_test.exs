defmodule Website45sV3.Game.QueueTest do
  use ExUnit.Case, async: true

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.QueueStarter

  defp from, do: {self(), make_ref()}

  # Marks a user as seated in a running game, backed by a stub process so
  # ActiveGames' monitor cleanup works as in production.
  defp seat_in_game(user_id) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    game_name = "stub_game_" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = ActiveGames.register_game(pid, game_name, [user_id])
    game_name
  end

  describe "QueueStarter dedup" do
    test "the same user cannot occupy two queue slots" do
      {:reply, :ok, state} =
        QueueStarter.handle_call({:add_player, {"Alice", "user_1"}}, from(), %{players: []})

      {:reply, :ok, state} =
        QueueStarter.handle_call({:add_player, {"Alice (tab 2)", "user_1"}}, from(), state)

      assert state.players == [{"Alice", "user_1"}]
    end

    test "removing a player empties their slot" do
      state = %{players: [{"Alice", "user_1"}, {"Bob", "user_2"}]}

      {:reply, :ok, state} = QueueStarter.handle_call({:remove_player, "user_1"}, from(), state)

      assert state.players == [{"Bob", "user_2"}]
    end

    test "a player seated in a running game cannot queue for another" do
      user_id = "in_game_" <> Integer.to_string(System.unique_integer([:positive]))
      seat_in_game(user_id)

      {:reply, {:error, :already_in_game}, state} =
        QueueStarter.handle_call({:add_player, {"Alice", user_id}}, from(), %{players: []})

      assert state.players == []
    end
  end

  describe "PrivateQueueManager" do
    test "creating lobbies is rate limited per owner" do
      state = %{queues: %{}, last_created: %{}}

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:create_queue, "q1", "owner"}, from(), state)

      {:reply, {:error, :too_soon}, _state} =
        PrivateQueueManager.handle_call({:create_queue, "q2", "owner"}, from(), state)
    end

    test "the same user cannot join a lobby twice" do
      state = %{queues: %{}, last_created: %{}}

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:add_player, "q1", {"Alice", "user_1"}}, from(), state)

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:add_player, "q1", {"Alice", "user_1"}}, from(), state)

      assert get_in(state.queues, ["q1", :players]) == [{"Alice", "user_1"}]
    end

    test "a player seated in a running game cannot join a lobby" do
      user_id = "in_game_" <> Integer.to_string(System.unique_integer([:positive]))
      seat_in_game(user_id)

      state = %{queues: %{}, last_created: %{}}

      {:reply, {:error, :already_in_game}, state} =
        PrivateQueueManager.handle_call({:add_player, "q1", {"Alice", user_id}}, from(), state)

      assert get_in(state.queues, ["q1", :players]) == nil
    end

    test "a private lobby can be filled with bots and starts a game" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      private_id = "test_lobby_" <> unique
      user_id = "lobby_human_" <> unique

      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")

      :ok = PrivateQueueManager.add_player(private_id, {"Host", user_id})

      bots =
        for n <- 1..3 do
          {:ok, pid} = BotSupervisor.start_private_bot(private_id, "Bot#{n}")
          pid
        end

      assert_receive {:redirect, "/game/" <> game_name}, 2_000

      assert [{game_pid, _}] = Registry.lookup(Website45sV3.Registry, game_name)
      state = GameController.get_game_state(game_pid)

      assert user_id in state.player_ids
      assert MapSet.size(state.seat_bots) == 3

      on_exit(fn ->
        Process.exit(game_pid, :kill)
        Enum.each(bots, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      end)
    end

    test "stale lobbies are swept and their players notified" do
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:sweep_test_user")

      three_hours_ago = System.monotonic_time(:millisecond) - 3 * 60 * 60 * 1000

      state = %{
        queues: %{
          "old" => %{
            players: [{"Alice", "sweep_test_user"}],
            owner: nil,
            created_at: three_hours_ago
          },
          "fresh" => %{
            players: [],
            owner: nil,
            created_at: System.monotonic_time(:millisecond)
          }
        },
        last_created: %{"someone" => 0}
      }

      {:noreply, state} = PrivateQueueManager.handle_info(:sweep, state)

      assert Map.keys(state.queues) == ["fresh"]
      assert state.last_created == %{}
      assert_receive :queue_closed
    end
  end
end
