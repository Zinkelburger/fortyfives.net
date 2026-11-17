defmodule Website45sV3Web.SlotRoutingTest do
  # Sets the app's slot and drains it: global state, so not async.
  use Website45sV3Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameSupervisor
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Slot

  setup do
    Application.put_env(:website_45s_v3, :slot, "blue")

    on_exit(fn ->
      Application.delete_env(:website_45s_v3, :slot)
      :persistent_term.erase({Slot, :draining})

      for {_, pid, _, _} <- DynamicSupervisor.which_children(BotSupervisor), is_pid(pid) do
        Process.exit(pid, :kill)
      end
    end)

    :ok
  end

  defp unique(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp anon_conn(conn, user_id) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user_id)
  end

  defp seat_in_game(user_id) do
    n = System.unique_integer([:positive])
    game = "slot_game_#{n}"
    players = [{"Me", user_id}, {"A", "bot_#{n}_a"}, {"B", "bot_#{n}_b"}, {"C", "bot_#{n}_c"}]
    {:ok, pid} = GameSupervisor.start_game(game, players)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    game
  end

  # Simulates draining without the broadcast reaching anyone first.
  defp set_draining, do: :persistent_term.put({Slot, :draining}, true)

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  describe "the plug" do
    test "names the slot in a cookie and a header", %{conn: conn} do
      conn = get(anon_conn(conn, unique("anon_")), ~p"/")

      assert conn.status == 200
      assert get_resp_header(conn, "x-ff-slot") == ["blue"]
      assert conn.resp_cookies["ff_slot"].value == "blue"
    end

    test "does nothing without a slot", %{conn: conn} do
      Application.delete_env(:website_45s_v3, :slot)
      conn = get(anon_conn(conn, unique("anon_")), ~p"/")

      assert get_resp_header(conn, "x-ff-slot") == []
      refute Map.has_key?(conn.resp_cookies, "ff_slot")
    end

    test "a draining slot sends a pinned visitor on to the live one", %{conn: conn} do
      set_draining()

      conn =
        anon_conn(conn, unique("anon_"))
        |> put_req_cookie("ff_slot", "blue")
        |> get("/play?tab=private")

      assert redirected_to(conn, 302) == "/play?tab=private"
      assert conn.resp_cookies["ff_slot"].max_age == 0
    end

    test "a draining slot keeps a player seated in one of its games", %{conn: conn} do
      user = unique("anon_")
      game = seat_in_game(user)
      set_draining()

      conn = anon_conn(conn, user) |> put_req_cookie("ff_slot", "blue") |> get(~p"/game/#{game}")

      assert conn.status == 200
      assert conn.resp_cookies["ff_slot"].value == "blue"
    end

    test "a draining slot serves a request nginx sent it as the live slot", %{conn: conn} do
      set_draining()
      conn = get(anon_conn(conn, unique("anon_")), ~p"/play")
      assert conn.status == 200
      # ...without pinning the browser to it.
      refute Map.has_key?(conn.resp_cookies, "ff_slot")
    end
  end

  describe "draining" do
    test "reloads an open page", %{conn: conn} do
      {:ok, view, _html} = live(anon_conn(conn, unique("anon_")), ~p"/")
      assert Slot.drain() =~ ~r/^\d+ \d+ draining$/
      assert_push_event(view, "ff-reload", %{})
    end

    test "leaves a seated player's pages alone", %{conn: conn} do
      user = unique("anon_")
      game = seat_in_game(user)
      {:ok, view, _html} = live(anon_conn(conn, user), ~p"/game/#{game}")
      {:ok, lobby, _html} = live(anon_conn(conn, user), ~p"/play")

      Slot.drain()
      refute_push_event(view, "ff-reload", %{}, 200)
      refute_push_event(lobby, "ff-reload", %{})
    end

    test "carries a queued player and their bots to the other slot", %{conn: conn} do
      user = unique("anon_")
      {:ok, view, _html} = live(anon_conn(conn, user), ~p"/play")
      view |> element("#join-queue-button") |> render_click()
      view |> element("#add-bot-button") |> render_click()

      Slot.drain()
      assert_push_event(view, "ff-reload", %{to: "/play?h=" <> token})

      assert {:ok, %{user: ^user, lobby: nil, join: true, bots: 1}} =
               Slot.verify_handoff(token, user)

      assert Slot.verify_handoff(token, unique("other_")) == :error
    end

    test "a click on a draining slot hands off instead", %{conn: conn} do
      user = unique("anon_")
      {:ok, view, _html} = live(anon_conn(conn, user), ~p"/play")
      set_draining()

      view |> element("#join-queue-button") |> render_click()
      assert_push_event(view, "ff-reload", %{to: "/play?h=" <> token})
      assert {:ok, %{join: true}} = Slot.verify_handoff(token, user)
      assert QueueStarter.player_count() == 0
    end
  end

  describe "arriving from the other slot" do
    test "opens the lobby and seats the player with their bots", %{conn: conn} do
      user = unique("anon_")
      lobby = Ecto.UUID.generate()
      token = Slot.handoff_token(%{user: user, lobby: lobby, join: true, bots: 2})

      {:ok, _view, _html} = live(anon_conn(conn, user), ~p"/play/private/#{lobby}?#{[h: token]}")

      wait_until(fn -> length(PrivateQueueManager.queue_players(lobby)) == 3 end)
      assert Enum.any?(PrivateQueueManager.queue_players(lobby), &(elem(&1, 1) == user))
    end

    test "rejoins the public queue", %{conn: conn} do
      user = unique("anon_")
      token = Slot.handoff_token(%{user: user, lobby: nil, join: true, bots: 0})

      {:ok, view, _html} = live(anon_conn(conn, user), ~p"/play?#{[h: token]}")

      assert render(view) =~ "You are in the queue"
      QueueStarter.release_player(user)
    end

    test "ignores a handoff made for someone else", %{conn: conn} do
      lobby = Ecto.UUID.generate()
      token = Slot.handoff_token(%{user: "someone", lobby: lobby, join: true, bots: 0})

      assert {:error, {:redirect, %{to: "/play"}}} =
               live(anon_conn(conn, unique("anon_")), ~p"/play/private/#{lobby}?#{[h: token]}")
    end

    test "opens the lobby a finished game on the other slot offered", %{conn: conn} do
      lobby = Ecto.UUID.generate()
      r = Slot.rematch_token(lobby)

      {:ok, _view, _html} =
        live(anon_conn(conn, unique("anon_")), ~p"/play/private/#{lobby}?#{[r: r]}")

      assert PrivateQueueManager.queue_exists?(lobby)
      assert Slot.verify_rematch(r, Ecto.UUID.generate()) == :error
    end
  end

  test "a game that ends on a draining slot frees the seat at once", %{conn: conn} do
    user = unique("anon_")
    game = seat_in_game(user)
    {:ok, view, _html} = live(anon_conn(conn, user), ~p"/game/#{game}")
    set_draining()

    send(view.pid, :game_end)
    assert_redirect(view, "/play")
    assert ActiveGames.find_game(user) == nil
  end
end
