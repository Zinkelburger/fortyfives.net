defmodule Website45sV3.Game.QueueTest do
  use ExUnit.Case, async: false

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Security.RateLimiter

  setup do
    :ok = RateLimiter.reset()
  end

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
      first_id = Ecto.UUID.generate()
      second_id = Ecto.UUID.generate()

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:create_queue, first_id, "owner"}, from(), state)

      {:reply, {:error, :too_soon}, _state} =
        PrivateQueueManager.handle_call({:create_queue, second_id, "owner"}, from(), state)
    end

    test "rotating session IDs cannot bypass the private-lobby network limit" do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)

      Application.put_env(:website_45s_v3, :security_rate_limits,
        login: [window_ms: 60_000, max_ip: 100, max_account: 100],
        queue: [window_ms: 60_000, max_ip: 100, max_create_ip: 1]
      )

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous)
        RateLimiter.reset()
      end)

      state = %{queues: %{}, last_created: %{}}

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call(
          {:create_queue, Ecto.UUID.generate(), "owner_1", "203.0.113.7"},
          from(),
          state
        )

      {:reply, {:error, :rate_limited}, _state} =
        PrivateQueueManager.handle_call(
          {:create_queue, Ecto.UUID.generate(), "owner_2", "203.0.113.7"},
          from(),
          state
        )
    end

    test "an empty lobby survives an unmount so the share link keeps working" do
      state = %{queues: %{}, last_created: %{}}
      private_id = Ecto.UUID.generate()

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:create_queue, private_id, "owner"}, from(), state)

      # QueueLive.terminate/2 fires on every unmount of the lobby page —
      # including a plain refresh by the owner, who has not joined yet.
      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:remove_player, private_id, "owner"}, from(), state)

      assert {:reply, true, state} =
               PrivateQueueManager.handle_call({:queue_exists, private_id}, from(), state)

      # ...and the owner can still join after coming back.
      assert {:reply, :ok, _state} =
               PrivateQueueManager.handle_call(
                 {:add_player, private_id, {"Alice", "owner"}},
                 from(),
                 state
               )
    end

    test "the last player can leave and rejoin their own lobby" do
      state = %{queues: %{}, last_created: %{}}
      private_id = Ecto.UUID.generate()

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:create_queue, private_id, "owner"}, from(), state)

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call(
          {:add_player, private_id, {"Alice", "user_1"}},
          from(),
          state
        )

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:remove_player, private_id, "user_1"}, from(), state)

      assert {:reply, :ok, state} =
               PrivateQueueManager.handle_call(
                 {:add_player, private_id, {"Alice", "user_1"}},
                 from(),
                 state
               )

      assert {:reply, [{"Alice", "user_1"}], _state} =
               PrivateQueueManager.handle_call({:queue_players, private_id}, from(), state)
    end

    test "a lobby left empty is reaped by the sweeper well before the full TTL" do
      long_ago = System.monotonic_time(:millisecond) - 30 * 60 * 1000

      state = %{
        queues: %{
          "abandoned" => %{
            players: [],
            owner: nil,
            created_at: System.monotonic_time(:millisecond),
            empty_since: long_ago
          },
          "occupied" => %{
            players: [{"Alice", "user_1"}],
            owner: nil,
            created_at: System.monotonic_time(:millisecond),
            empty_since: nil
          }
        },
        last_created: %{}
      }

      {:noreply, state} = PrivateQueueManager.handle_info(:sweep, state)

      assert Map.keys(state.queues) == ["occupied"]
    end

    test "the same user cannot join a lobby twice" do
      state = %{queues: %{}, last_created: %{}}
      private_id = Ecto.UUID.generate()

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:create_queue, private_id, "owner"}, from(), state)

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call(
          {:add_player, private_id, {"Alice", "user_1"}},
          from(),
          state
        )

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call(
          {:add_player, private_id, {"Alice", "user_1"}},
          from(),
          state
        )

      assert get_in(state.queues, [private_id, :players]) == [{"Alice", "user_1"}]
    end

    test "joining an unknown or malformed lobby never allocates it" do
      state = %{queues: %{}, last_created: %{}}

      {:reply, {:error, :queue_not_found}, state} =
        PrivateQueueManager.handle_call(
          {:add_player, Ecto.UUID.generate(), {"Alice", "user_1"}},
          from(),
          state
        )

      {:reply, {:error, :invalid_id}, state} =
        PrivateQueueManager.handle_call({:create_queue, "not-a-uuid", "owner"}, from(), state)

      assert state.queues == %{}
    end

    test "a player seated in a running game cannot join a lobby" do
      user_id = "in_game_" <> Integer.to_string(System.unique_integer([:positive]))
      seat_in_game(user_id)

      state = %{queues: %{}, last_created: %{}}
      private_id = Ecto.UUID.generate()

      {:reply, :ok, state} =
        PrivateQueueManager.handle_call({:create_queue, private_id, "owner"}, from(), state)

      {:reply, {:error, :already_in_game}, state} =
        PrivateQueueManager.handle_call(
          {:add_player, private_id, {"Alice", user_id}},
          from(),
          state
        )

      assert get_in(state.queues, [private_id, :players]) == []
    end

    test "a private lobby can be filled with bots and starts a game" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      private_id = Ecto.UUID.generate()
      user_id = "lobby_human_" <> unique

      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")

      :ok = PrivateQueueManager.create_queue(private_id, user_id)
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
