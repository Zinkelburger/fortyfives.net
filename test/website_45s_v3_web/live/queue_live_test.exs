defmodule Website45sV3Web.QueueLiveTest do
  # These tests exercise globally named processes (QueueStarter,
  # BotSupervisor, ActiveGames), so they must not run alongside other tests.
  use Website45sV3Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.GameSupervisor
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.QueueStarter

  defp unique(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

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

    test "abandoning hands the seat to a bot and frees the user to queue", %{conn: conn} do
      user = unique("qlt_user_")
      {_game_name, game_pid} = start_active_game(user)

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play")

      html = render_click(view, "abandon_game")
      assert html =~ "A bot will finish it for you"

      state = GameController.get_game_state(game_pid)
      assert MapSet.member?(state.abandoned_players, user)
      assert MapSet.member?(state.auto_play_players, user)
      assert ActiveGames.find_game(user) == nil

      assert render_click(view, "join") =~ "You are in the queue"
    end

    test "an abandoned player cannot re-enter the game", %{conn: conn} do
      user = unique("qlt_user_")
      {game_name, game_pid} = start_active_game(user)

      send(game_pid, {:abandon_game, user})
      _sync = GameController.get_game_state(game_pid)

      assert {:error, {:live_redirect, %{to: "/play"}}} =
               conn |> anon_conn(user) |> live(~p"/game/#{game_name}")
    end
  end

  describe "adding bots" do
    test "bots can be added back-to-back without a cooldown", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = unique("qlt_lobby_")

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      render_click(view, "request_bot")
      render_click(view, "request_bot")

      players = PrivateQueueManager.queue_players(private_id)
      assert players |> Enum.map(fn {name, _id} -> name end) |> Enum.sort() == ["Bot1", "Bot2"]
    end

    test "one user can have at most 3 bots waiting in a queue", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = unique("qlt_lobby_")

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      for _ <- 1..3, do: render_click(view, "request_bot")
      html = render_click(view, "request_bot")

      assert html =~ "You already have 3 bots waiting"
      assert length(PrivateQueueManager.queue_players(private_id)) == 3
    end

    test "fill_bots starts a private game in one click", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      user = unique("qlt_user_")
      private_id = unique("qlt_lobby_")
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user}")

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play/private/#{private_id}")

      render_click(view, "fill_bots")

      assert_receive {:redirect, "/game/" <> game_name}, 2_000
      on_exit(fn -> kill_game(game_name) end)

      [{game_pid, _}] = Registry.lookup(Website45sV3.Registry, game_name)
      state = GameController.get_game_state(game_pid)

      assert user in state.player_ids
      assert MapSet.size(state.seat_bots) == 3
      assert ActiveGames.find_game(user) == game_name
    end

    test "Play vs Bots starts a public game in one click", %{conn: conn} do
      on_exit(&kill_all_bots/0)
      # Straggler cleanup from earlier tests can lag by a moment.
      wait_until(fn -> QueueStarter.player_count() == 0 end)

      user = unique("qlt_user_")
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user}")

      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/play")

      render_click(view, "fill_bots")

      assert_receive {:redirect, "/game/" <> game_name}, 2_000
      on_exit(fn -> kill_game(game_name) end)

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
      assert render_click(view, "fill_bots") =~ "Rejoin or abandon your current game first"
      assert BotSupervisor.bot_count() == 0
    end
  end
end
