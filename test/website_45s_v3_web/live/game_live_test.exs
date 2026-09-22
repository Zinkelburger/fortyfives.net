defmodule Website45sV3Web.GameLiveTest do
  # Drives real game processes registered globally, so it must not run
  # alongside other tests.
  use Website45sV3Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Website45sV3.Game.Card
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.GameSupervisor

  defp unique(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp anon_conn(conn, user_id) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user_id)
  end

  # Starts a four-human game seating `user_id` first. Nobody else acts, so
  # the game only moves when the test drives it.
  defp start_game(user_id) do
    n = System.unique_integer([:positive])
    game_name = "glt_game_#{n}"

    players = [
      {"Me", user_id},
      {"Ann", "glt_#{n}_a"},
      {"Ben", "glt_#{n}_b"},
      {"Cat", "glt_#{n}_c"}
    ]

    {:ok, pid} = GameSupervisor.start_game(game_name, players)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {game_name, pid}
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

  # Bids through to the discard phase: the first bidder takes 15 hearts.
  defp drive_to_discard(pid) do
    wait_until(fn ->
      state = GameController.get_game_state(pid)

      case state do
        %{phase: "Discard"} ->
          true

        %{phase: "Bidding", current_player_id: player, winning_bid: {0, _, _}} ->
          send(pid, {:player_bid, player, "15", :hearts})
          false

        %{phase: "Bidding", current_player_id: player} ->
          send(pid, {:player_bid, player, "0", :pass})
          false
      end
    end)
  end

  # Makes `user_id` the dealer, on turn, facing a 20 hearts bid.
  defp set_up_dealer_hold(pid, user_id) do
    :sys.replace_state(pid, fn state ->
      bidder = Enum.find(state.player_ids, &(&1 != user_id))

      %{
        state
        | dealing_player_id: user_id,
          current_player_id: user_id,
          winning_bid: {20, bidder, :hearts},
          bids_placed: 3,
          bagged: false
      }
    end)
  end

  # Discards for everyone so the game enters the Playing phase.
  defp drive_to_playing(pid) do
    drive_to_discard(pid)

    wait_until(fn ->
      state = GameController.get_game_state(pid)

      case {state.phase, state.player_ids -- state.received_discards_from} do
        {"Playing", _} ->
          true

        {"Discard", [player | _]} ->
          keep = state.hands[player] |> Enum.take(5) |> Enum.map(&Card.encode/1)
          send(pid, {:confirm_discard, player, keep})
          false

        _ ->
          false
      end
    end)
  end

  describe "mount" do
    test "renders the seated player's hand with accessible cards", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, pid} = start_game(user)

      {:ok, _view, html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      state = GameController.get_game_state(pid)
      assert html =~ ~s(id="game-container")
      assert html =~ ~s(data-phase="Bidding")

      for card <- state.hands[user] do
        assert html =~ ~s(data-card-value="#{Card.encode(card)}")
        assert html =~ ~s(alt="#{Card.to_string(card)}")
        assert html =~ ~s(aria-label="#{Card.to_string(card)}")
      end

      # Other players' cards are never rendered.
      for {id, hand} <- state.hands, id != user, card <- hand do
        refute html =~ ~s(data-card-value="#{Card.encode(card)}")
      end

      # Cards are keyboard operable: Enter (keydown) and Space (keyup) both
      # dispatch the click the CardSelection hook listens for.
      [card | _] = state.hands[user]
      assert html =~ ~s(phx-keydown="[[&quot;dispatch&quot;)
      assert html =~ ~s(phx-key="Enter")
      assert html =~ ~s(phx-key=" ")
      assert html =~ ~s(id="hand-card-#{Card.encode(card)}")
    end

    test "a user who is not seated is sent back to the lobby", %{conn: conn} do
      {game_name, _pid} = start_game(unique("glt_user_"))

      assert {:error, {:live_redirect, %{to: "/play"}}} =
               conn |> anon_conn(unique("stranger_")) |> live(~p"/game/#{game_name}")
    end

    test "an unknown game is sent back to the lobby", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/play"}}} =
               conn |> anon_conn(unique("glt_user_")) |> live(~p"/game/nope")
    end
  end

  describe "events" do
    test "malformed play-card payloads are ignored", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, pid} = start_game(user)
      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      before = GameController.get_game_state(pid)

      render_hook(view, "play-card", %{"cards" => ["x_hearts"]})
      render_hook(view, "play-card", %{"cards" => [123]})
      render_hook(view, "play-card", %{"cards" => "5_hearts"})
      render_hook(view, "play-card", %{"cards" => ["5_hearts", "6_hearts"]})
      render_hook(view, "play-card", %{})

      assert Process.alive?(view.pid)
      assert render(view) =~ ~s(id="game-container")
      assert GameController.get_game_state(pid).hands == before.hands
    end

    test "a stray :queue_closed message does not crash the view", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, _pid} = start_game(user)
      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      send(view.pid, :queue_closed)
      send(view.pid, {:something, :unexpected})

      assert render(view) =~ ~s(id="game-container")
      assert Process.alive?(view.pid)
    end
  end

  describe "session replay" do
    alias Website45sV3.Analytics

    defp replay_batch(seq, extra \\ %{}) do
      Map.merge(
        %{
          "seq" => seq,
          "data" => ~s([{"type":4,"timestamp":1}]),
          "clicks" => [],
          "now" => System.os_time(:millisecond)
        },
        extra
      )
    end

    test "batches are stored with their clicks on the server's clock", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, _pid} = start_game(user)
      {:ok, view, html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")
      assert html =~ ~s(data-record="true")

      # The browser's clock is a minute slow; the click was 1s before it sent.
      now = System.os_time(:millisecond)
      browser_now = now - 60_000

      render_hook(
        view,
        "replay_chunk",
        replay_batch(0, %{
          "device" => "mobile",
          "w" => 390,
          "h" => 800,
          "clicks" => [%{"ts" => browser_now - 1_000, "el" => "button#x", "dead" => false}],
          "now" => browser_now
        })
      )

      render_hook(view, "replay_chunk", replay_batch(1))

      assert [replay] = Analytics.list_replays(game_name: game_name)
      assert %{chunk_count: 2, display_name: "Me", device: "mobile", viewport_w: 390} = replay

      assert [{"Me", %{"el" => "button#x", "dead" => false}, at_ms}] =
               Analytics.list_clicks(game_name)

      assert_in_delta at_ms, now - 1_000, 2_000
      assert render(view) =~ ~s(data-record="true")
    end

    test "a batch over the size cap ends the recording and later batches are ignored",
         %{conn: conn} do
      user = unique("glt_user_")
      {game_name, _pid} = start_game(user)
      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      huge = "[" <> String.duplicate("1,", 600_000) <> "1]"
      render_hook(view, "replay_chunk", replay_batch(0, %{"data" => huge}))

      assert render(view) =~ ~s(data-record="false")
      render_hook(view, "replay_chunk", replay_batch(1))

      assert [%{chunk_count: 0}] = Analytics.list_replays(game_name: game_name)
      assert Process.alive?(view.pid)
    end

    test "a database failure ends the recording instead of crashing the table",
         %{conn: conn} do
      user = unique("glt_user_")
      {game_name, _pid} = start_game(user)
      {:ok, view, _html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      # Nobody may check out a connection any more: every query in the view
      # process raises, as it would with the pool exhausted.
      Ecto.Adapters.SQL.Sandbox.mode(Website45sV3.Repo, :manual)

      render_hook(view, "replay_chunk", replay_batch(0))

      assert Process.alive?(view.pid)
      assert render(view) =~ ~s(id="game-container")
      assert render(view) =~ ~s(data-record="false")
    end
  end

  describe "discard" do
    test "a refresh mid-discard shows the discard as already confirmed", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, pid} = start_game(user)
      drive_to_discard(pid)

      keep =
        GameController.get_game_state(pid).hands[user] |> Enum.take(3) |> Enum.map(&Card.encode/1)

      send(pid, {:confirm_discard, user, keep})
      wait_until(fn -> user in GameController.get_game_state(pid).received_discards_from end)

      {:ok, _view, html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      assert html =~ ~s(data-phase="Discard")
      assert html =~ ~s(data-confirm-discard-clicked="true")
      assert html =~ "Waiting for other players..."
      assert html =~ ~s(id="confirm-discard-button")
      assert html =~ ~r/id="confirm-discard-button"[^>]*disabled/
      # only the kept cards are shown
      assert length(Regex.scan(~r/data-card-value=/, html)) == 3
    end

    test "before confirming, the discard prompt is live", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, pid} = start_game(user)
      drive_to_discard(pid)

      {:ok, _view, html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      assert html =~ ~s(data-confirm-discard-clicked="false")
      assert html =~ "Select the cards you want to keep"
      refute html =~ ~r/id="confirm-discard-button"[^>]*disabled/
    end
  end

  describe "playing" do
    test "the table renders for the player on turn and for a waiting player", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, pid} = start_game(user)
      drive_to_playing(pid)

      state = GameController.get_game_state(pid)
      on_turn = state.current_player_id
      waiting = Enum.find(state.player_ids, &(&1 != on_turn))

      {:ok, _view, html} = live(anon_conn(conn, on_turn), ~p"/game/#{game_name}")
      assert html =~ "Your turn"
      assert html =~ "played-cards"

      {:ok, _view, html} = live(anon_conn(conn, waiting), ~p"/game/#{game_name}")
      assert html =~ "#{state.player_map[on_turn]}&#39;s turn"
    end

    test "a played card is reflected in every seated view", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, pid} = start_game(user)
      drive_to_playing(pid)

      state = GameController.get_game_state(pid)
      on_turn = state.current_player_id
      legal = Map.get(state.legal_moves, on_turn, state.hands[on_turn])
      card = List.first(legal)

      {:ok, view, _html} = live(anon_conn(conn, user), ~p"/game/#{game_name}")

      send(pid, {:play_card, on_turn, card})
      wait_until(fn -> GameController.get_game_state(pid).played_cards != [] end)

      html = render(view)
      assert html =~ Card.encode(card)
    end
  end

  describe "bidding" do
    test "the dealer is offered a hold at the current high bid", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, pid} = start_game(user)
      set_up_dealer_hold(pid, user)

      {:ok, view, html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      assert html =~ "As dealer you may hold at 20"
      assert html =~ ~s(data-dealer="true")
      assert html =~ ~s(data-current-bid="20")
      # 15 is below the bid, 20 is the hold, 25 raises
      assert html =~ ~r/phx-value-bid-number="15"[^>]*disabled/
      refute html =~ ~r/phx-value-bid-number="20"[^>]*disabled/
      refute html =~ ~r/phx-value-bid-number="25"[^>]*disabled/

      view |> element(~s(button[phx-value-bid-number="20"])) |> render_click()
      view |> element(~s(button[phx-value-bid-suit="clubs"])) |> render_click()
      view |> element("#confirm-bid-button") |> render_click()

      wait_until(fn -> GameController.get_game_state(pid).phase == "Discard" end)
      state = GameController.get_game_state(pid)
      assert state.winning_bid == {20, user, :clubs}
      assert state.trump == :clubs

      assert render(view) =~ ~s(data-phase="Discard")
    end

    test "a non-dealer must outbid", %{conn: conn} do
      user = unique("glt_user_")
      {game_name, pid} = start_game(user)

      :sys.replace_state(pid, fn state ->
        bidder = Enum.find(state.player_ids, &(&1 != user))
        dealer = Enum.find(state.player_ids, &(&1 not in [user, bidder]))

        %{
          state
          | dealing_player_id: dealer,
            current_player_id: user,
            winning_bid: {20, bidder, :hearts},
            bids_placed: 1
        }
      end)

      {:ok, view, html} = conn |> anon_conn(user) |> live(~p"/game/#{game_name}")

      refute html =~ "you may hold"
      assert html =~ ~r/phx-value-bid-number="20"[^>]*disabled/
      refute html =~ ~r/phx-value-bid-number="25"[^>]*disabled/

      # Even if the client forges the selection, the view refuses it.
      render_click(view, "set_bid_number", %{"bid-number" => "20"})
      render_click(view, "set_bid_suit", %{"bid-suit" => "clubs"})
      assert render_click(view, "confirm_bid") =~ "Your bid must be higher than the current bid."

      state = GameController.get_game_state(pid)
      assert {20, bidder, :hearts} = state.winning_bid
      assert bidder != user
      assert state.current_player_id == user
    end
  end
end
