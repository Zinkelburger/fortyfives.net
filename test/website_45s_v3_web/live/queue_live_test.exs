defmodule Website45sV3Web.QueueLiveTest do
  # These tests exercise globally named processes (QueueStarter,
  # BotSupervisor, ActiveGames), so they must not run alongside other tests.
  use Website45sV3Web.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.GameSupervisor
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3Web.Presence

  defp unique(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp create_private_lobby(owner_id) do
    private_id = Ecto.UUID.generate()
    :ok = PrivateQueueManager.create_queue(private_id, owner_id)
    private_id
  end

  defp anon_conn(conn, user_id) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user_id)
  end

  # Starts a real game seating `user_id` with three bot seats, as the public
  # queue would after "Play vs Bots".
  defp start_active_game(user_id) do
    n = System.unique_integer([:positive])
    game_name = "qlt_game_#{n}"

    players = [
      {"Me", user_id},
      {"Ann", "bot_#{n}_a"},
      {"Ben", "bot_#{n}_b"},
      {"Cat", "bot_#{n}_c"}
    ]

    {:ok, pid} = GameSupervisor.start_game(game_name, players)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {game_name, pid}
  end

  defp kill_all_bots do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(BotSupervisor), is_pid(pid) do
      Process.exit(pid, :kill)
    end
  end

  defp kill_game(game_name) do
    case Registry.lookup(Website45sV3.Registry, game_name) do
      [{pid, _}] -> Process.exit(pid, :kill)
      [] -> :ok
    end
  end

  defp wait_until(fun, tries \\ 100) do
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

  # Shuts a LiveView down the way closing its browser tab does: the process
  # exits and `terminate/2` runs.
  defp close_tab(view) do
    GenServer.stop(view.pid, :normal)
    wait_until(fn -> not Process.alive?(view.pid) end)
  end

  defp queue_metas(topic, user_id) do
    case Presence.get_by_key(topic, user_id) do
      %{metas: metas} -> metas
      [] -> []
    end
  end

  defp player_cards(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".player-card")
    |> Enum.map(&LazyHTML.text/1)
  end

  describe "session identity" do
    test "mounting without a session user id fails instead of sharing an identity" do
      conn = Phoenix.ConnTest.build_conn() |> Phoenix.ConnTest.init_test_session(%{})

      assert_raise RuntimeError, ~r/user_id missing from the session/, fn ->
        live_isolated(conn, Website45sV3Web.QueueLive, session: %{})
      end
    end
  end

  describe "tabs" do
    test "the tab is chosen by the URL and unknown tabs fall back to the queue", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/play?tab=private")
      assert html =~ "Create Private Game"
      refute html =~ "Join Queue"

      {:ok, _view, html} = live(conn, ~p"/play?tab=<script>")
      assert html =~ "Join Queue"
      refute html =~ "Create Private Game"
    end

    test "switching tabs patches the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play")

      html = view |> element("a.tab", "Play a Friend") |> render_click()
      assert_patch(view, ~p"/play?tab=private")
      assert html =~ "Create Private Game"

      view |> element("a.tab", "Public Queue") |> render_click()
      assert_patch(view, ~p"/play")
      assert render(view) =~ "Join Queue"
    end
  end

  describe "two tabs of one session" do
    setup do
      # Stragglers from other tests leave the queue asynchronously.
      wait_until(fn -> QueueStarter.player_count() == 0 end)
      :ok
    end

    test "closing a tab that never joined keeps the other tab's queue entry", %{conn: conn} do
      user = unique("qlt_user_")
      {:ok, tab_a, _html} = conn |> anon_conn(user) |> live(~p"/play")
      {:ok, tab_b, _html} = conn |> anon_conn(user) |> live(~p"/play")

      assert render_click(tab_a, "join") =~ "You are in the queue"
      assert QueueStarter.player_count() == 1

      close_tab(tab_b)

      assert QueueStarter.player_count() == 1
      assert [_meta] = queue_metas("queue", user)
      assert render(tab_a) =~ "You are in the queue"

      close_tab(tab_a)
      wait_until(fn -> QueueStarter.player_count() == 0 end)
    end

    test "a player queued from two tabs stays queued until the last tab closes", %{conn: conn} do
      user = unique("qlt_user_")
      {:ok, tab_a, _html} = conn |> anon_conn(user) |> live(~p"/play")
      {:ok, tab_b, _html} = conn |> anon_conn(user) |> live(~p"/play")

      render_click(tab_a, "join")
      render_click(tab_b, "join")
      assert QueueStarter.player_count() == 1
      assert [_, _] = queue_metas("queue", user)

      close_tab(tab_b)
      assert QueueStarter.player_count() == 1
      assert [_meta] = queue_metas("queue", user)

      close_tab(tab_a)
      wait_until(fn -> QueueStarter.player_count() == 0 end)
      assert queue_metas("queue", user) == []
    end

    test "a player with two tabs is shown as one card", %{conn: conn} do
      user = unique("qlt_user_")
      {:ok, tab_a, _html} = conn |> anon_conn(user) |> live(~p"/play")
      {:ok, tab_b, _html} = conn |> anon_conn(user) |> live(~p"/play")

      render_click(tab_a, "join")
      render_click(tab_b, "join")

      # Wait for the second presence diff to reach tab A before rendering.
      wait_until(fn ->
        length(:sys.get_state(tab_a.pid).socket.assigns.queue[user].metas) == 2
      end)

      assert player_cards(render(tab_a)) == ["Anonymous"]
      assert player_cards(render(tab_b)) == ["Anonymous"]

      close_tab(tab_a)
      close_tab(tab_b)
    end

    test "closing a private lobby tab that never joined keeps the lobby entry", %{conn: conn} do
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      path = ~p"/play/private/#{private_id}"

      {:ok, tab_a, _html} = conn |> anon_conn(user) |> live(path)
      {:ok, tab_b, _html} = conn |> anon_conn(user) |> live(path)

      assert render_click(tab_a, "join") =~ "You are in the game lobby"
      assert [{_name, ^user}] = PrivateQueueManager.queue_players(private_id)

      close_tab(tab_b)

      assert [{_name, ^user}] = PrivateQueueManager.queue_players(private_id)
      assert render(tab_a) =~ "You are in the game lobby"

      close_tab(tab_a)
      wait_until(fn -> PrivateQueueManager.queue_players(private_id) == [] end)
    end
  end

  describe "leaving" do
    test "leaving removes the player and their card", %{conn: conn} do
      wait_until(fn -> QueueStarter.player_count() == 0 end)
      user = unique("qlt_user_")
      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play")

      render_click(view, "join")
      assert QueueStarter.player_count() == 1

      html = render_click(view, "leave")
      assert html =~ "Join Queue"
      assert player_cards(html) == []
      assert QueueStarter.player_count() == 0
      assert queue_metas("queue", user) == []
    end
  end

  defp departures(user) do
    Website45sV3.Repo.all(
      from(e in Website45sV3.Analytics.SiteEvent,
        where: e.player_id == ^user and e.name == "queue_leave"
      )
    )
  end

  describe "queue departure analytics" do
    test "closing the public queue records the departure", %{conn: conn} do
      wait_until(fn -> QueueStarter.player_count() == 0 end)
      user = unique("qlt_user_")
      {:ok, view, _} = conn |> anon_conn(user) |> live(~p"/play")
      render_click(view, "join")
      close_tab(view)
      assert QueueStarter.player_count() == 0
      assert [%{data: %{"reason" => "disconnect", "queue" => "public"}}] = departures(user)
    end

    test "only the last tab closing records a departure with its wait", %{conn: conn} do
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      path = ~p"/play/private/#{private_id}"
      {:ok, tab_a, _} = conn |> anon_conn(user) |> live(path)
      {:ok, tab_b, _} = conn |> anon_conn(user) |> live(path)
      render_click(tab_a, "join")
      render_click(tab_b, "join")

      close_tab(tab_a)
      assert departures(user) == []
      close_tab(tab_b)

      assert [%{data: %{"reason" => "disconnect", "queue" => "private", "waited_ms" => wait}}] =
               departures(user)

      assert is_integer(wait) and wait >= 0
    end

    test "explicit leave is idempotent and closing the tab does not count twice", %{conn: conn} do
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      {:ok, view, _} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")
      render_click(view, "leave")
      assert departures(user) == []
      render_click(view, "join")
      render_click(view, "leave")
      render_click(view, "leave")
      close_tab(view)
      assert [%{data: %{"reason" => "explicit"}}] = departures(user)
    end

    test "leaving one tab preserves another tab's membership", %{conn: conn} do
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      path = ~p"/play/private/#{private_id}"
      {:ok, tab_a, _} = conn |> anon_conn(user) |> live(path)
      {:ok, tab_b, _} = conn |> anon_conn(user) |> live(path)
      render_click(tab_a, "join")
      render_click(tab_b, "join")
      render_click(tab_a, "leave")
      assert [{_, ^user}] = PrivateQueueManager.queue_players(private_id)
      assert departures(user) == []
      close_tab(tab_a)
      close_tab(tab_b)
      assert length(departures(user)) == 1
    end

    test "a matched player leaving the lobby is not a queue drop-off", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user}")
      {:ok, view, _} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")
      render_click(view, "join")
      for _ <- 1..3, do: render_click(view, "request_bot")
      assert_receive {:redirect, "/game/" <> game_name}, 2_000
      on_exit(fn -> kill_game(game_name) end)
      wait_until(fn -> not Process.alive?(view.pid) end)
      assert departures(user) == []
    end
  end

  describe "rejoin banner" do
    test "the lobby offers rejoin instead of the queue while a game is running", %{conn: conn} do
      user = unique("qlt_user_")
      {game_name, _pid} = start_active_game(user)

      {:ok, _view, html} = conn |> anon_conn(user) |> live(~p"/play")

      assert html =~ "You have a game in progress"
      assert html =~ "Playing with Ann, Ben, Cat"
      assert html =~ "/game/#{game_name}"
      refute html =~ "Join Queue"
      refute html =~ "Play vs Bots"
    end

    test "the banner survives a page reload", %{conn: conn} do
      user = unique("qlt_user_")
      {game_name, _pid} = start_active_game(user)

      # Two independent mounts (e.g. closing the tab and coming back) both
      # find the game — no PubSub race involved.
      {:ok, _view, html1} = conn |> anon_conn(user) |> live(~p"/play")
      {:ok, _view, html2} = conn |> anon_conn(user) |> live(~p"/play")

      assert html1 =~ "/game/#{game_name}"
      assert html2 =~ "/game/#{game_name}"
    end

    test "joining the queue is refused while a game is running", %{conn: conn} do
      # Stragglers from other tests leave the queue asynchronously.
      wait_until(fn -> QueueStarter.player_count() == 0 end)

      user = unique("qlt_user_")
      {_game_name, _pid} = start_active_game(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play")

      assert render_click(view, "join") =~ "You already have a game in progress"
      assert QueueStarter.player_count() == 0
    end

    test "abandoning a game against bots ends it and frees the user to queue", %{conn: conn} do
      user = unique("qlt_user_")
      {_game_name, game_pid} = start_active_game(user)
      ref = Process.monitor(game_pid)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play")

      html = render_click(view, "abandon_game")
      assert html =~ "You left your game."

      assert_receive {:DOWN, ^ref, :process, ^game_pid, :normal}, 500
      assert ActiveGames.find_game(user) == nil

      assert render_click(view, "join") =~ "You are in the queue"
    end

    test "an abandoned player cannot re-enter the game", %{conn: conn} do
      user = unique("qlt_user_")
      {game_name, game_pid} = start_active_game(user)

      ref = Process.monitor(game_pid)
      send(game_pid, {:abandon_game, user})
      assert_receive {:DOWN, ^ref, :process, ^game_pid, :normal}, 500

      assert {:error, {:live_redirect, %{to: "/play"}}} =
               conn |> anon_conn(user) |> live(~p"/game/#{game_name}")
    end
  end

  describe "adding bots" do
    test "bots can be added back-to-back without a cooldown", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      render_click(view, "request_bot")
      render_click(view, "request_bot")

      players = PrivateQueueManager.queue_players(private_id)
      assert players |> Enum.map(fn {name, _id} -> name end) |> Enum.sort() == ["Bot1", "Bot2"]
    end

    test "one user can have at most 3 bots waiting in a queue", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      for _ <- 1..3, do: render_click(view, "request_bot")
      html = render_click(view, "request_bot")

      assert html =~ "You already have 3 bots waiting"
      assert length(PrivateQueueManager.queue_players(private_id)) == 3
    end

    test "the add-bot button counts filled seats", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      assert view |> element("#add-bot-button") |> render() =~ "0/4"
      render_click(view, "join")
      render_click(view, "request_bot")

      wait_until(fn -> view |> element("#add-bot-button") |> render() =~ "2/4" end)
      refute has_element?(view, "#fill-bots-button")
    end

    test "adding a bot to the last seat starts a private game", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user}")

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      render_click(view, "join")
      for _ <- 1..3, do: render_click(view, "request_bot")

      assert_receive {:redirect, "/game/" <> game_name}, 2_000
      on_exit(fn -> kill_game(game_name) end)

      [{game_pid, _}] = Registry.lookup(Website45sV3.Registry, game_name)
      state = GameController.get_game_state(game_pid)

      assert user in state.player_ids
      assert MapSet.size(state.seat_bots) == 3
      assert ActiveGames.find_game(user) == game_name
    end

    test "adding a bot to the last seat starts a public game", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      # Straggler cleanup from earlier tests can lag by a moment.
      wait_until(fn -> QueueStarter.player_count() == 0 end)

      user = unique("qlt_user_")
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user}")

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play")

      render_click(view, "join")
      for _ <- 1..3, do: render_click(view, "request_bot")

      assert_receive {:redirect, "/game/" <> game_name}, 2_000
      on_exit(fn -> kill_game(game_name) end)

      # The game page is in another live_session, so the lobby sends the
      # browser there with a full redirect rather than a live navigation.
      assert_redirect(view, "/game/#{game_name}")

      [{game_pid, _}] = Registry.lookup(Website45sV3.Registry, game_name)
      state = GameController.get_game_state(game_pid)

      assert user in state.player_ids
      assert ActiveGames.find_game(user) == game_name
    end

    test "bot requests are refused while a game is running", %{conn: conn} do
      # Bots killed by earlier tests can take a moment to leave the supervisor.
      wait_until(fn -> BotSupervisor.bot_count() == 0 end)

      user = unique("qlt_user_")
      {_game_name, _pid} = start_active_game(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play")

      assert render_click(view, "request_bot") =~ "Rejoin or abandon your current game first"
      assert BotSupervisor.bot_count() == 0
    end
  end
end
