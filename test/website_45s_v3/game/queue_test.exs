defmodule Website45sV3.Game.QueueTest do
  # Exercises the globally named queue processes, so it must not run
  # alongside other tests.
  use ExUnit.Case, async: false

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Security.RateLimiter
  alias Website45sV3Web.Presence

  setup do
    :ok = RateLimiter.reset()
  end

  defp unique(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  # Marks a user as seated in a running game, backed by a stub process so
  # ActiveGames' monitor cleanup works as in production.
  defp seat_in_game(user_id) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)

    game_name = "stub_game_" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = ActiveGames.register_game(pid, game_name, [user_id])
    game_name
  end

  # Creates a private lobby owned by a fresh user (lobby creation is rate
  # limited per owner).
  defp create_lobby do
    private_id = Ecto.UUID.generate()
    :ok = PrivateQueueManager.create_queue(private_id, unique("owner_"))
    private_id
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  describe "QueueStarter" do
    test "the same user cannot occupy two queue slots" do
      user_id = unique("queue_user_")
      on_exit(fn -> QueueStarter.remove_player({"Alice", user_id}) end)

      before = QueueStarter.player_count()

      :ok = QueueStarter.add_player({"Alice", user_id})
      :ok = QueueStarter.add_player({"Alice (tab 2)", user_id})

      assert QueueStarter.player_count() == before + 1
    end

    test "removing a player empties their slot" do
      user_id = unique("queue_user_")
      before = QueueStarter.player_count()

      :ok = QueueStarter.add_player({"Alice", user_id})
      assert QueueStarter.player_count() == before + 1

      :ok = QueueStarter.remove_player({"Alice", user_id})
      assert QueueStarter.player_count() == before
    end

    test "a player seated in a running game cannot queue for another" do
      user_id = unique("in_game_")
      seat_in_game(user_id)
      before = QueueStarter.player_count()

      assert {:error, :already_in_game} = QueueStarter.add_player({"Alice", user_id})
      assert QueueStarter.player_count() == before
    end
  end

  describe "PrivateQueueManager" do
    test "creating lobbies is rate limited per owner" do
      owner = unique("owner_")

      assert :ok = PrivateQueueManager.create_queue(Ecto.UUID.generate(), owner)
      assert {:error, :too_soon} = PrivateQueueManager.create_queue(Ecto.UUID.generate(), owner)
    end

    test "a lobby id cannot be created twice" do
      private_id = create_lobby()

      assert {:error, :already_exists} =
               PrivateQueueManager.create_queue(private_id, unique("owner_"))
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

      ip = "203.0.113.7"

      assert :ok = PrivateQueueManager.create_queue(Ecto.UUID.generate(), unique("owner_"), ip)

      assert {:error, :rate_limited} =
               PrivateQueueManager.create_queue(Ecto.UUID.generate(), unique("owner_"), ip)
    end

    test "an empty lobby survives an unmount so the share link keeps working" do
      private_id = create_lobby()
      owner = unique("owner_")

      # A repeated/no-op cleanup preserves the link and reports that no
      # membership ended, so analytics cannot count a phantom departure.
      assert :not_queued = PrivateQueueManager.remove_player(private_id, owner)

      assert PrivateQueueManager.queue_exists?(private_id)

      # ...and the owner can still join after coming back.
      assert :ok = PrivateQueueManager.add_player(private_id, {"Alice", owner})
    end

    test "the last player can leave and rejoin their own lobby" do
      private_id = create_lobby()
      user_id = unique("user_")

      :ok = PrivateQueueManager.add_player(private_id, {"Alice", user_id})
      :ok = PrivateQueueManager.remove_player(private_id, user_id)
      assert PrivateQueueManager.queue_players(private_id) == []

      assert :ok = PrivateQueueManager.add_player(private_id, {"Alice", user_id})
      assert PrivateQueueManager.queue_players(private_id) == [{"Alice", user_id}]
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
      private_id = create_lobby()
      user_id = unique("user_")

      :ok = PrivateQueueManager.add_player(private_id, {"Alice", user_id})
      :ok = PrivateQueueManager.add_player(private_id, {"Alice", user_id})

      assert PrivateQueueManager.queue_players(private_id) == [{"Alice", user_id}]
    end

    test "joining an unknown or malformed lobby never allocates it" do
      unknown = Ecto.UUID.generate()

      assert {:error, :queue_not_found} =
               PrivateQueueManager.add_player(unknown, {"Alice", unique("user_")})

      refute PrivateQueueManager.queue_exists?(unknown)

      assert {:error, :invalid_id} =
               PrivateQueueManager.create_queue("not-a-uuid", unique("owner_"))

      refute PrivateQueueManager.queue_exists?("not-a-uuid")
    end

    test "a player seated in a running game cannot join a lobby" do
      user_id = unique("in_game_")
      seat_in_game(user_id)
      private_id = create_lobby()

      assert {:error, :already_in_game} =
               PrivateQueueManager.add_player(private_id, {"Alice", user_id})

      assert PrivateQueueManager.queue_players(private_id) == []
    end

    test "a private lobby can be filled with bots and starts a game" do
      private_id = create_lobby()
      user_id = unique("lobby_human_")

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

      # Every bot — including the one whose join started the game — heard
      # about the redirect: they left the lobby and sit at the table.
      wait_until(fn -> Presence.list("private_queue:#{private_id}") == %{} end)
      wait_until(fn -> map_size(Presence.list(game_name)) == 3 end)

      # Bots follow the game's life: a killed game must not leak them.
      Process.exit(game_pid, :kill)
      wait_until(fn -> Enum.all?(bots, &(not Process.alive?(&1))) end)
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
