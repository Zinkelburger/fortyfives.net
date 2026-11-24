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
  alias Website45sV3.Security.RateLimiter
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

  defp game_pid(game_name) do
    [{pid, _}] = Registry.lookup(Website45sV3.Registry, game_name)
    pid
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

  # Closes a LiveView the way a phone does when its browser goes to the
  # background or the network drops: the socket closes under it.
  defp drop_connection(view) do
    # The test is linked to the view through LiveViewTest's proxy.
    Process.flag(:trap_exit, true)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, {:shutdown, :closed})
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
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

  describe "signing in from a lobby" do
    test "the private lobby's links return to it, through registering and logging in",
         %{conn: conn} do
      lobby = "/play/private/#{create_private_lobby(unique("owner"))}"
      query = URI.encode_query(return_to: lobby)

      {:ok, _lv, html} = live(conn, lobby)
      assert html =~ ~s(href="/users/register?#{Plug.HTML.html_escape(query)}")
      assert html =~ ~s(href="/users/log_in?#{Plug.HTML.html_escape(query)}")

      conn = get(conn, "/users/register?#{query}")
      assert get_session(conn, :user_return_to) == lobby

      user = Website45sV3.AccountsFixtures.user_fixture()

      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{
            "username_or_email" => user.email,
            "password" => Website45sV3.AccountsFixtures.valid_user_password()
          }
        })

      assert redirected_to(conn) == lobby
    end

    test "the public lobby's links return to it", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/play")
      assert html =~ "/users/log_in?return_to=%2Fplay"
    end

    test "other pages' links carry no lobby", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/learn")
      assert html =~ ~s(href="/users/log_in")
    end
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

  defp departures(user), do: site_events(user, "queue_leave")

  defp site_events(user, name) do
    Website45sV3.Repo.all(
      from(e in Website45sV3.Analytics.SiteEvent,
        where: e.player_id == ^user and e.name == ^name
      )
    )
  end

  describe "queue departure analytics" do
    test "a private lobby's events carry its tag", %{conn: conn} do
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      tag = PrivateQueueManager.lobby_tag(private_id)
      {:ok, view, _} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")
      render_click(view, "join")
      render_click(view, "leave")

      assert [%{data: %{"lobby" => ^tag}}] = site_events(user, "page_view")
      assert [%{data: %{"lobby" => ^tag, "queue" => "private"}}] = site_events(user, "queue_join")

      assert [%{data: %{"lobby" => ^tag, "reason" => "explicit"}}] =
               site_events(user, "queue_leave")
    end

    test "creating a private lobby records its tag", %{conn: conn} do
      user = unique("qlt_user_")
      {:ok, view, _} = conn |> anon_conn(user) |> live(~p"/play?tab=private")

      assert {:error, {:live_redirect, %{to: "/play/private/" <> private_id}}} =
               render_click(view, "create_private")

      tag = PrivateQueueManager.lobby_tag(private_id)
      assert [%{data: %{"lobby" => ^tag}}] = site_events(user, "private_created")
    end

    test "closing the public queue records the departure", %{conn: conn} do
      wait_until(fn -> QueueStarter.player_count() == 0 end)
      user = unique("qlt_user_")
      {:ok, view, _} = conn |> anon_conn(user) |> live(~p"/play")
      render_click(view, "join")
      close_tab(view)
      assert QueueStarter.player_count() == 0
      assert [%{data: %{"reason" => "disconnect", "queue" => "public"}}] = departures(user)
    end

    test "a lobby killed without terminate/2 still leaves the queue", %{conn: conn} do
      wait_until(fn -> QueueStarter.player_count() == 0 end)
      user = unique("qlt_user_")
      {:ok, view, _} = conn |> anon_conn(user) |> live(~p"/play")
      render_click(view, "join")
      assert QueueStarter.player_count() == 1

      # A live navigation to another lobby page: Phoenix shuts the old
      # LiveView down with an exit signal, and terminate/2 does not run.
      Process.flag(:trap_exit, true)
      Process.exit(view.pid, :kill)

      wait_until(fn -> QueueStarter.player_count() == 0 end)
      wait_until(fn -> departures(user) != [] end)
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

      assert [%{data: %{"action" => "join", "reason" => "already_in_game", "queue" => "public"}}] =
               site_events(user, "refused")
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

      assert {:error, {:redirect, %{to: "/play"}}} =
               conn |> anon_conn(user) |> live(~p"/game/#{game_name}")
    end
  end

  describe "a private table's seats" do
    test "creating the table seats its creator", %{conn: conn} do
      user = unique("qlt_user_")
      conn = anon_conn(conn, user)

      {:ok, view, _html} = live(conn, ~p"/play?tab=private")

      {:error, {:live_redirect, %{to: "/play/private/" <> private_id = path}}} =
        render_click(view, "create_private")

      assert [{"Anonymous1", ^user}] = PrivateQueueManager.queue_players(private_id)

      {:ok, lobby, html} = live(conn, path)

      assert html =~ "You are in the game lobby"
      assert has_element?(lobby, "#leave-queue-button")
      assert player_cards(html) == ["Anonymous"]
      assert [%{display_name: "Anonymous"}] = queue_metas("private_queue:#{private_id}", user)
    end

    test "a lost connection keeps the seat and coming back takes it", %{conn: conn} do
      user = unique("qlt_user_")
      friend = unique("qlt_user_")
      private_id = create_private_lobby(user)
      path = ~p"/play/private/#{private_id}"
      topic = "private_queue:#{private_id}"

      {:ok, friend_view, _html} = conn |> anon_conn(friend) |> live(path)
      {:ok, view, _html} = conn |> anon_conn(user) |> live(path)
      render_click(view, "join")

      drop_connection(view)

      wait_until(fn -> match?([%{away: true}], queue_metas(topic, user)) end)
      assert [{_name, ^user}] = PrivateQueueManager.queue_players(private_id)

      wait_until(fn -> render(friend_view) =~ "away" end)
      assert friend_view |> element("#add-bot-button") |> render() =~ "1/4"

      {:ok, back, html} = conn |> anon_conn(user) |> live(path)

      assert html =~ "You are in the game lobby"
      assert has_element?(back, "#leave-queue-button")
      assert [{_name, ^user}] = PrivateQueueManager.queue_players(private_id)
      wait_until(fn -> match?([%{display_name: "Anonymous"}], queue_metas(topic, user)) end)
      refute hd(queue_metas(topic, user))[:away]
      wait_until(fn -> not (render(friend_view) =~ "away") end)
    end

    test "leaving the lobby still gives the seat up at once", %{conn: conn} do
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")
      render_click(view, "join")
      render_click(view, "leave")

      assert PrivateQueueManager.queue_players(private_id) == []
      refute PrivateQueueManager.seated?(private_id, user)
    end

    test "a visitor who never joined is not seated by opening the link", %{conn: conn} do
      private_id = create_private_lobby(unique("qlt_user_"))
      visitor = unique("qlt_user_")

      {:ok, view, _html} = conn |> anon_conn(visitor) |> live(~p"/play/private/#{private_id}")

      assert has_element?(view, "#join-queue-button")
      assert PrivateQueueManager.queue_players(private_id) == []
    end

    test "the link of a table that started takes a seated player to the game", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      path = ~p"/play/private/#{private_id}"
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user}")

      {:ok, view, _html} = conn |> anon_conn(user) |> live(path)
      render_click(view, "join")
      drop_connection(view)

      for n <- 1..3, do: {:ok, _pid} = BotSupervisor.start_private_bot(private_id, "Bot#{n}")

      assert_receive {:redirect, "/game/" <> game_name}, 2_000
      on_exit(fn -> kill_game(game_name) end)
      wait_until(fn -> GameController.lobby(game_pid(game_name)) != nil end)

      assert {:error, {:redirect, %{to: to}}} = conn |> anon_conn(user) |> live(path)
      assert to == "/game/#{game_name}"

      # Anyone else finds the link spent.
      assert {:error, {:redirect, %{to: "/play"}}} =
               conn |> anon_conn(unique("qlt_user_")) |> live(path)
    end
  end

  describe "suggesting bots" do
    test "after a wait in the public queue the page says how many bots start the game",
         %{conn: conn} do
      on_exit(&kill_all_bots/0)
      wait_until(fn -> QueueStarter.player_count() == 0 end)
      wait_until(fn -> Presence.list("queue") == %{} end)

      {:ok, view, _html} = conn |> anon_conn(unique("qlt_user_")) |> live(~p"/play")

      render_click(view, "join")
      refute has_element?(view, "#bot-hint")

      send(view.pid, :suggest_bots)
      assert has_element?(view, "#bot-hint", "Add 3 bots to start")
      assert has_element?(view, ".bot-hint-on #add-bot-button")

      render_click(view, "request_bot")
      wait_until(fn -> has_element?(view, "#bot-hint", "Add 2 bots to start") end)
      render_click(view, "request_bot")
      wait_until(fn -> has_element?(view, "#bot-hint", "Add 1 bot to start") end)

      hinted =
        Website45sV3.Repo.all(
          from(e in Website45sV3.Analytics.SiteEvent,
            where: e.name == "bot_added",
            select: e.data
          )
        )

      assert Enum.map(hinted, & &1["hinted"]) == [true, true]
    end

    test "a player who left the queue is not told to add bots", %{conn: conn} do
      {:ok, view, _html} = conn |> anon_conn(unique("qlt_user_")) |> live(~p"/play")

      render_click(view, "join")
      render_click(view, "leave")
      send(view.pid, :suggest_bots)

      refute has_element?(view, "#bot-hint")
    end

    test "a private table does not suggest bots", %{conn: conn} do
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      render_click(view, "join")
      send(view.pid, :suggest_bots)

      refute has_element?(view, "#bot-hint")
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

      assert players |> Enum.map(fn {name, _id} -> name end) |> Enum.sort() ==
               ["Anonymous1", "Bot1", "Bot2"]
    end

    test "adding a bot seats the player who asked for it", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = create_private_lobby(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      assert render_click(view, "request_bot") =~ "You are in the game lobby"
      assert [{_name, ^user}, {"Bot1", _bot}] = PrivateQueueManager.queue_players(private_id)
      assert has_element?(view, "#leave-queue-button")
    end

    # The failure this replaced: someone looking at the lobby without a seat
    # added bots until the table was full, and the game started without them.
    test "a table cannot be filled with bots without the player who added them",
         %{conn: conn} do
      on_exit(&kill_all_bots/0)
      owner = unique("qlt_user_")
      friend = unique("qlt_user_")
      private_id = create_private_lobby(owner)
      path = ~p"/play/private/#{private_id}"
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{owner}")

      {:ok, friend_view, _html} = conn |> anon_conn(friend) |> live(path)
      render_click(friend_view, "join")

      {:ok, owner_view, _html} = conn |> anon_conn(owner) |> live(path)
      for _ <- 1..2, do: render_click(owner_view, "request_bot")

      assert_receive {:redirect, "/game/" <> game_name}, 2_000
      on_exit(fn -> kill_game(game_name) end)

      [{game_pid, _}] = Registry.lookup(Website45sV3.Registry, game_name)
      state = GameController.get_game_state(game_pid)

      assert owner in state.player_ids
      assert friend in state.player_ids
      assert MapSet.size(state.seat_bots) == 2
    end

    test "asking for a bot with three players seated takes the last seat instead",
         %{conn: conn} do
      on_exit(&kill_all_bots/0)
      private_id = create_private_lobby(unique("qlt_user_"))
      path = ~p"/play/private/#{private_id}"

      for _ <- 1..3 do
        {:ok, view, _html} = conn |> anon_conn(unique("qlt_user_")) |> live(path)
        render_click(view, "join")
      end

      fourth = unique("qlt_user_")
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{fourth}")
      {:ok, view, _html} = conn |> anon_conn(fourth) |> live(path)
      render_click(view, "request_bot")

      assert_receive {:redirect, "/game/" <> game_name}, 2_000
      on_exit(fn -> kill_game(game_name) end)

      [{game_pid, _}] = Registry.lookup(Website45sV3.Registry, game_name)
      assert MapSet.size(GameController.get_game_state(game_pid).seat_bots) == 0
      assert BotSupervisor.bot_count() == 0
    end

    test "bots are budgeted per network, not per session", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      limits = Application.get_env(:website_45s_v3, :security_rate_limits, [])
      on_exit(fn -> Application.put_env(:website_45s_v3, :security_rate_limits, limits) end)
      RateLimiter.reset()

      Application.put_env(
        :website_45s_v3,
        :security_rate_limits,
        Keyword.put(limits, :bots, max_ip: 2)
      )

      # Fresh sessions each time: the per-session cap never applies.
      for _ <- 1..2 do
        user = unique("qlt_user_")
        private_id = create_private_lobby(user)
        {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")
        refute render_click(view, "request_bot") =~ "added a lot of bots"
      end

      user = unique("qlt_user_")
      private_id = create_private_lobby(user)
      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      assert render_click(view, "request_bot") =~ "added a lot of bots"
      assert [{_name, ^user}] = PrivateQueueManager.queue_players(private_id)
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

      # The game knows it came from this lobby, for its game log.
      assert %{queue: "private", lobby: lobby} = :sys.get_state(game_pid)
      assert lobby == PrivateQueueManager.lobby_tag(private_id)
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
