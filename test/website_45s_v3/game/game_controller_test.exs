defmodule Website45sV3.Game.GameControllerTest do
  use ExUnit.Case

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.Card
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.GameEvents
  alias Website45sV3.Game.Rules

  @humans [
    {"Alice", "human_1"},
    {"Bob", "human_2"},
    {"Carol", "human_3"},
    {"Dave", "human_4"}
  ]

  setup_all do
    Application.ensure_all_started(:phoenix_pubsub)

    maybe_start_supervised(
      {Registry, keys: :unique, name: Website45sV3.Registry},
      Website45sV3.Registry
    )

    maybe_start_supervised({Phoenix.PubSub, name: Website45sV3.PubSub}, Website45sV3.PubSub)
    :ok
  end

  defp maybe_start_supervised(spec, name) do
    if Process.whereis(name) do
      :ok
    else
      start_supervised!(spec)
    end
  end

  defp unique_game_name do
    "test_game_" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp stop_game(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  end

  defp start_test_game(players) do
    game_name = unique_game_name()
    {:ok, pid} = GameController.start_link({game_name, players})
    on_exit(fn -> stop_game(pid) end)
    pid
  end

  defp unique_players do
    unique = System.unique_integer([:positive])
    for n <- 1..4, do: {"Player#{n}", "abandon_h#{n}_#{unique}"}
  end

  test "start_game tracks permanent bots separately from autoplay players" do
    pid =
      start_test_game([
        {"Bot1", "bot_1"},
        {"Alice", "human_1"},
        {"Bob", "human_2"},
        {"Carol", "human_3"}
      ])

    state = GameController.get_game_state(pid)

    assert state.seat_bots == MapSet.new(["bot_1"])
    assert state.auto_play_players == MapSet.new()
    assert state.all_bot_controlled_timer_ref == nil
  end

  test "all-bot games arm the all-bot-controlled timeout immediately" do
    pid =
      start_test_game([
        {"Bot1", "bot_1"},
        {"Bot2", "bot_2"},
        {"Bot3", "bot_3"},
        {"Bot4", "bot_4"}
      ])

    state = GameController.get_game_state(pid)

    assert state.seat_bots == MapSet.new(["bot_1", "bot_2", "bot_3", "bot_4"])
    assert state.auto_play_players == MapSet.new()
    assert state.all_bot_controlled_timer_ref != nil
  end

  test "teams follow the queue join order" do
    pid = start_test_game(@humans)
    state = GameController.get_game_state(pid)

    # 1st & 3rd joined vs 2nd & 4th joined
    assert state.player_ids == ["human_1", "human_2", "human_3", "human_4"]
  end

  test "refuses to start with duplicated players" do
    players = [
      {"Alice", "human_1"},
      {"Alice again", "human_1"},
      {"Bob", "human_2"},
      {"Carol", "human_3"}
    ]

    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_players, _}} =
             GameController.start_link({unique_game_name(), players})
  end

  test "malformed discard payloads are ignored instead of crashing the game" do
    pid = start_test_game(@humans)
    drive_bidding!(pid)

    state = GameController.get_game_state(pid)
    assert state.phase == "Discard"
    [player | _] = state.player_ids

    send(pid, {:confirm_discard, player, ["garbage"]})
    send(pid, {:confirm_discard, player, ["5_hearts_oops", 123]})
    send(pid, {:confirm_discard, player, "not-a-list"})
    send(pid, {:confirm_discard, player, [nil]})

    # a synchronous call proves the process handled the messages and survived
    state = GameController.get_game_state(pid)
    assert Process.alive?(pid)
    assert state.phase == "Discard"
    assert state.received_discards_from == []
  end

  test "a card the player does not hold is rejected" do
    pid = start_test_game(@humans)
    drive_bidding!(pid)
    drive_discards!(pid)

    state = GameController.get_game_state(pid)
    assert state.phase == "Playing"
    current = state.current_player_id

    not_in_hand =
      all_cards()
      |> Enum.find(fn card -> card not in state.hands[current] end)

    send(pid, {:play_card, current, not_in_hand})
    send(pid, {:play_card, current, "10_hearts"})

    state = GameController.get_game_state(pid)
    assert state.played_cards == []
    assert state.current_player_id == current
  end

  test "a full game can be played to completion" do
    pid = start_test_game(@humans)

    final_state = drive_until_final_scoring!(pid)

    assert final_state.phase == "Final Scoring"

    assert final_state.team_scores.team1 >= 120 or
             final_state.team_scores.team2 >= 120

    rounds = length(final_state.team_1_history)
    assert rounds >= 1
    assert length(final_state.team_2_history) == rounds

    assert Enum.any?(final_state.actions, &String.contains?(&1, "won the game!"))
    assert Process.alive?(pid)

    # The event log followed the whole game and persists as readable JSON.
    kinds = final_state.events |> Enum.map(& &1["e"]) |> Enum.uniq()

    for kind <- ~w(deal bid kitty discard play_start play trick score) do
      assert kind in kinds, "no #{kind} event logged"
    end

    attrs = GameEvents.finalize(final_state, :normal)
    assert attrs.ended == "finished"
    assert final_state.winning_team in [:team1, :team2]
    assert attrs.winner == Atom.to_string(final_state.winning_team)
    assert Enum.any?(final_state.actions, &String.contains?(&1, "won the game!"))
    assert attrs.hands == rounds
    assert attrs.human_count == 4
    assert {:ok, %{"events" => events}} = GameEvents.decode(attrs.events)
    assert length(events) == attrs.event_count
    assert Enum.all?(events, &is_integer(&1["t"]))
  end

  describe "bidding" do
    test "the dealer may hold at the current high bid and names trump" do
      pid = start_test_game(@humans)
      state = GameController.get_game_state(pid)
      dealer = state.dealing_player_id
      [first, second, third] = bidders_before_dealer(state)

      bid!(pid, first, "20", :hearts)
      bid!(pid, second, "0", :pass)
      bid!(pid, third, "0", :pass)

      state = GameController.get_game_state(pid)
      assert state.current_player_id == dealer
      assert state.winning_bid == {20, first, :hearts}

      bid!(pid, dealer, "20", :clubs)

      state = GameController.get_game_state(pid)
      assert state.phase == "Discard"
      assert state.winning_bid == {20, dealer, :clubs}
      assert state.trump == :clubs
      # the dealer received the kitty
      assert length(state.hands[dealer]) == 8
    end

    test "a player who is not the dealer cannot hold" do
      pid = start_test_game(@humans)
      state = GameController.get_game_state(pid)
      [first, second, _third] = bidders_before_dealer(state)

      bid!(pid, first, "20", :hearts)
      send(pid, {:player_bid, second, "20", :clubs})

      state = GameController.get_game_state(pid)
      assert state.current_player_id == second
      assert state.winning_bid == {20, first, :hearts}
      assert state.bids_placed == 1
    end

    test "the phase turns on the number of bids, not the log" do
      pid = start_test_game(@humans)
      state = GameController.get_game_state(pid)
      [first, second, third] = bidders_before_dealer(state)

      bid!(pid, first, "0", :pass)
      bid!(pid, second, "0", :pass)
      bid!(pid, third, "0", :pass)

      state = GameController.get_game_state(pid)
      assert state.bids_placed == 3
      assert state.bagged
      assert state.phase == "Bidding"

      # A bagged dealer cannot pass.
      send(pid, {:player_bid, state.dealing_player_id, "0", :pass})
      state = GameController.get_game_state(pid)
      assert state.phase == "Bidding"

      bid!(pid, state.dealing_player_id, "15", :spades)
      state = GameController.get_game_state(pid)
      assert state.phase == "Discard"
      assert state.bids_placed == 4
    end
  end

  describe "per-seat views" do
    test "a player's view holds only their own hand" do
      pid = start_test_game(@humans)
      state = GameController.get_game_state(pid)

      assert {:ok, view} = GameController.get_player_view(pid, "human_2")

      assert view.hand == state.hands["human_2"]
      assert view.hand_counts == %{"human_1" => 5, "human_2" => 5, "human_3" => 5, "human_4" => 5}
      assert view.phase == "Bidding"
      assert view.dealing_player_id == state.dealing_player_id
      refute view.auto_playing

      for secret <- [:hands, :deck, :discard_pile, :turn_timer, :discard_timers] do
        refute Map.has_key?(view, secret), "#{secret} leaked into the player view"
      end
    end

    test "strangers and abandoned players get no view" do
      pid = start_test_game(@humans)

      assert {:error, :not_seated} = GameController.get_player_view(pid, "someone_else")

      send(pid, {:abandon_game, "human_3"})
      assert {:error, :not_seated} = GameController.get_player_view(pid, "human_3")
    end

    test "broadcasts carry each player's own redacted view" do
      pid = start_test_game(@humans)
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:human_1")
      join_presence(pid, ["human_1"])

      state = GameController.get_game_state(pid)
      bid!(pid, state.current_player_id, "15", :hearts)

      assert_receive {:update_state, view}
      assert view.hand == GameController.get_game_state(pid).hands["human_1"]
      refute Map.has_key?(view, :hands)
      refute Map.has_key?(view, :deck)
      assert view.winning_bid == {15, state.current_player_id, :hearts}
    end
  end

  describe "timers" do
    test "presence changes and resume requests do not reset a running turn clock" do
      pid = start_test_game(@humans)
      state = GameController.get_game_state(pid)
      current = state.current_player_id
      other = Enum.find(state.player_ids, &(&1 != current))

      assert %{player_id: ^current, phase: "Bidding", kind: :idle, ref: ref} = state.turn_timer
      assert is_integer(Process.read_timer(ref))

      join_presence(pid, [other, current])
      send(pid, {:resume_control, current})
      leave_presence(pid, [other])

      assert %{ref: ^ref} = GameController.get_game_state(pid).turn_timer
      assert is_integer(Process.read_timer(ref))
    end

    test "idling out hands the seat to a bot; coming back hands it to the player" do
      pid = start_test_game(@humans)
      state = GameController.get_game_state(pid)
      current = state.current_player_id
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{current}")

      send(pid, {:idle_timeout, current, "Bidding"})
      assert_receive :auto_playing

      state = GameController.get_game_state(pid)
      assert MapSet.member?(state.auto_play_players, current)

      # The bot moves (bot_move_delay is 10ms in tests) so the turn passes.
      wait_until(fn -> GameController.get_game_state(pid).current_player_id != current end)
      state = GameController.get_game_state(pid)
      assert state.turn_timer.player_id == state.current_player_id
      assert state.turn_timer.kind == :idle

      join_presence(pid, [current])
      assert_receive :auto_play_disabled
      refute MapSet.member?(GameController.get_game_state(pid).auto_play_players, current)
    end

    test "discard clocks run once per player and stop as players discard" do
      pid = start_test_game(@humans)
      drive_bidding!(pid)

      state = GameController.get_game_state(pid)
      assert state.phase == "Discard"
      assert state.turn_timer == nil
      assert Map.keys(state.discard_timers) |> Enum.sort() == Enum.sort(state.player_ids)
      refs = Map.new(state.discard_timers, fn {player, timer} -> {player, timer.ref} end)

      join_presence(pid, ["human_2"])

      assert Map.new(GameController.get_game_state(pid).discard_timers, fn {p, t} ->
               {p, t.ref}
             end) ==
               refs

      [player | _] = state.player_ids
      keep = state.hands[player] |> Enum.take(5) |> Enum.map(&Card.encode/1)
      send(pid, {:confirm_discard, player, keep})

      state = GameController.get_game_state(pid)
      refute Map.has_key?(state.discard_timers, player)
      assert map_size(state.discard_timers) == 3
    end

    test "the fifth trick ends the hand without scheduling a lead or a clock" do
      # Long enough for the assertions below to observe the Scoring phase.
      override_timings(scoring_display: 500)

      pid = start_test_game(@humans)
      :erlang.trace(pid, true, [:receive])

      state = drive!(pid, fn state -> state.phase == "Scoring" end)

      assert state.current_player_id == nil
      assert state.turn_timer == nil
      assert state.discard_timers == %{}
      assert state.trick_winning_cards == []

      # Exactly four "winner leads next" transitions: tricks 1-4, never 5.
      leads =
        collect_traced(pid, fn
          {:transition_to_end_bid, _} -> true
          _ -> false
        end)

      assert leads == 4

      # ...and the next hand starts on the clock again.
      state = drive!(pid, fn state -> state.phase == "Bidding" end)
      assert state.turn_timer.player_id == state.current_player_id
    end
  end

  describe "scoring" do
    test "the best trump bonus goes to the highest trump, not the last trick's led suit" do
      pid = start_test_game(@humans)

      # human_4 (team 2) wins the last trick with the ace of hearts, the best
      # trump of the hand. Team 1 bid 15 and only took 10 (2 tricks): -15.
      final_trick(pid,
        trump: :clubs,
        winners: [
          {"human_2", 13, :spades},
          {"human_1", 2, :clubs},
          {"human_3", 13, :diamonds},
          {"human_4", 12, :diamonds}
        ],
        table: [{"human_1", 4, :diamonds}, {"human_2", 3, :diamonds}, {"human_3", 5, :diamonds}],
        to_play: {"human_4", 1, :hearts}
      )

      state = drive!(pid, fn state -> state.phase == "Scoring" end)
      assert state.team_scores == %{team1: -15, team2: 20}
    end

    test "no bonus is paid when no trump was played" do
      pid = start_test_game(@humans)

      # Diamonds led in the last trick; K♦ won an earlier trick. Under the
      # old "compare with the last suit led" rule that king would have been
      # paid the bonus. human_3 (team 1) wins the last trick with the 5♦.
      final_trick(pid,
        trump: :clubs,
        winners: [
          {"human_2", 13, :spades},
          {"human_1", 10, :spades},
          {"human_3", 13, :diamonds},
          {"human_4", 12, :diamonds}
        ],
        table: [{"human_1", 4, :diamonds}, {"human_2", 3, :diamonds}, {"human_3", 5, :diamonds}],
        to_play: {"human_4", 13, :hearts}
      )

      state = drive!(pid, fn state -> state.phase == "Scoring" end)
      assert state.team_scores == %{team1: 15, team2: 10}
    end
  end

  describe "bot seats" do
    test "an all-bot game plays itself from the game process" do
      pid =
        start_test_game([
          {"Bot1", "bot_1"},
          {"Bot2", "bot_2"},
          {"Bot3", "bot_3"},
          {"Bot4", "bot_4"}
        ])

      wait_until(fn -> GameController.get_game_state(pid).trick_winning_cards != [] end, 500)
    end
  end

  describe "active-game tracking and abandonment" do
    test "starting a game registers its human players" do
      players = unique_players()
      game_name = unique_game_name()
      {:ok, pid} = GameController.start_link({game_name, players})
      on_exit(fn -> stop_game(pid) end)

      for {_name, id} <- players do
        assert ActiveGames.find_game(id) == game_name
      end
    end

    test "abandoning hands the seat to a bot and frees the session" do
      [{_, quitter_id} | _] = players = unique_players()
      game_name = unique_game_name()
      {:ok, pid} = GameController.start_link({game_name, players})
      on_exit(fn -> stop_game(pid) end)

      send(pid, {:abandon_game, quitter_id})
      state = GameController.get_game_state(pid)

      assert MapSet.member?(state.abandoned_players, quitter_id)
      assert MapSet.member?(state.auto_play_players, quitter_id)
      assert ActiveGames.find_game(quitter_id) == nil

      # The other seats are untouched.
      for {_name, id} <- tl(players) do
        assert ActiveGames.find_game(id) == game_name
        refute MapSet.member?(state.abandoned_players, id)
      end
    end

    test "an abandoned player cannot resume control of their seat" do
      [{_, quitter_id} | _] = players = unique_players()
      {:ok, pid} = GameController.start_link({unique_game_name(), players})
      on_exit(fn -> stop_game(pid) end)

      send(pid, {:abandon_game, quitter_id})
      send(pid, {:resume_control, quitter_id})
      state = GameController.get_game_state(pid)

      assert MapSet.member?(state.auto_play_players, quitter_id)
      assert MapSet.member?(state.abandoned_players, quitter_id)
    end

    test "abandonment survives the end of a round" do
      [{_, quitter_id} | _] = players = unique_players()
      {:ok, pid} = GameController.start_link({unique_game_name(), players})
      on_exit(fn -> stop_game(pid) end)

      send(pid, {:abandon_game, quitter_id})
      # :end_scoring rebuilds most of the state for the next round.
      send(pid, :end_scoring)
      state = GameController.get_game_state(pid)

      assert MapSet.member?(state.abandoned_players, quitter_id)
    end
  end

  ## Game-driving helpers

  # The three players who bid before the dealer, in bidding order.
  defp bidders_before_dealer(state) do
    dealer_index = Enum.find_index(state.player_ids, &(&1 == state.dealing_player_id))
    for offset <- 1..3, do: Enum.at(state.player_ids, rem(dealer_index + offset, 4))
  end

  defp bid!(pid, player, bid, suit) do
    state = GameController.get_game_state(pid)
    assert state.current_player_id == player
    send(pid, {:player_bid, player, bid, suit})
    wait_for_change(pid, state)
  end

  defp join_presence(pid, players) do
    game = GameController.get_game_state(pid).game_name
    for player <- players, do: Website45sV3Web.Presence.track(self(), game, player, %{})
    sync_presence(pid)
  end

  defp leave_presence(pid, players) do
    game = GameController.get_game_state(pid).game_name
    for player <- players, do: Website45sV3Web.Presence.untrack(self(), game, player)
    sync_presence(pid)
  end

  defp sync_presence(pid) do
    send(pid, %Phoenix.Socket.Broadcast{event: "presence_diff"})
    GameController.get_game_state(pid)
  end

  defp override_timings(overrides) do
    previous = Application.get_env(:website_45s_v3, :game_timings, [])
    Application.put_env(:website_45s_v3, :game_timings, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:website_45s_v3, :game_timings, previous) end)
  end

  # Counts the messages received by the traced `pid` matching `match?`.
  defp collect_traced(pid, match?, count \\ 0) do
    receive do
      {:trace, ^pid, :receive, message} ->
        collect_traced(pid, match?, if(match?.(message), do: count + 1, else: count))
    after
      0 -> count
    end
  end

  # Injects a hand that is one card away from its fifth trick: `winners`
  # are the four tricks already won, `table` the cards already played to
  # the fifth, and `to_play` the current player's last card.
  defp final_trick(pid, opts) do
    card = fn {player, value, suit} -> %{player_id: player, card: Card.new(value, suit)} end
    {to_play_player, to_play_value, to_play_suit} = opts[:to_play]
    to_play_card = Card.new(to_play_value, to_play_suit)
    winners = Enum.map(opts[:winners], card)

    round_scores =
      Enum.reduce(winners, %{team1: 0, team2: 0}, fn %{player_id: player}, scores ->
        team = Rules.team_for(Enum.map(@humans, &elem(&1, 1)), player)
        Map.update!(scores, team, &(&1 + 5))
      end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | phase: "Playing",
          current_player_id: to_play_player,
          hands: Map.new(state.player_ids, &{&1, []}) |> Map.put(to_play_player, [to_play_card]),
          played_cards: opts[:table] |> Enum.map(card) |> Enum.reverse(),
          suit_led: opts[:table] |> List.first() |> elem(2),
          trump: opts[:trump],
          trick_winning_cards: Enum.reverse(winners),
          round_scores: round_scores,
          legal_moves: %{},
          winning_bid: {15, "human_1", opts[:trump]},
          actions: []
      }
    end)

    send(pid, {:play_card, to_play_player, to_play_card})
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

  # Bids 15 hearts with the first player to act, then passes the rest.
  defp drive_bidding!(pid) do
    drive!(pid, fn state -> state.phase != "Bidding" end)
  end

  defp drive_discards!(pid) do
    drive!(pid, fn state -> state.phase not in ["Bidding", "Discard"] end)
  end

  defp drive_until_final_scoring!(pid) do
    drive!(pid, fn state -> state.phase == "Final Scoring" end)
  end

  # Steps the game forward (bid, discard, play) until `done?.(state)`.
  defp drive!(pid, done?, steps \\ 0)

  defp drive!(_pid, _done?, steps) when steps > 20_000 do
    flunk("game did not reach the expected state within #{steps} steps")
  end

  defp drive!(pid, done?, steps) do
    state = GameController.get_game_state(pid)

    if done?.(state) do
      state
    else
      case next_move(state) do
        nil ->
          # waiting on a game-internal transition timer
          Process.sleep(2)

        message ->
          send(pid, message)
          wait_for_change(pid, state)
      end

      drive!(pid, done?, steps + 1)
    end
  end

  # The scripted move for the current state: the first bidder bids 15
  # hearts and everyone else passes, players keep their first five cards,
  # and the first legal card is played.
  defp next_move(%{phase: "Bidding", current_player_id: player} = state) when player != nil do
    {highest, _, _} = state.winning_bid

    cond do
      state.bagged -> {:player_bid, player, "15", :hearts}
      highest == 0 -> {:player_bid, player, "15", :hearts}
      true -> {:player_bid, player, "0", :pass}
    end
  end

  defp next_move(%{phase: "Discard"} = state) do
    case state.player_ids -- state.received_discards_from do
      [] ->
        nil

      [player | _] ->
        keep = state.hands[player] |> Enum.take(5) |> Enum.map(&Card.encode/1)
        {:confirm_discard, player, keep}
    end
  end

  defp next_move(%{phase: "Playing", current_player_id: player} = state) when player != nil do
    hand = state.hands[player]
    legal = Map.get(state.legal_moves, player, hand)
    {:play_card, player, List.first(legal) || List.first(hand)}
  end

  defp next_move(_state), do: nil

  defp wait_for_change(pid, previous_state, waited \\ 0) do
    if waited > 2_000 do
      flunk("game state did not change after an action")
    end

    state = GameController.get_game_state(pid)

    if fingerprint(state) == fingerprint(previous_state) do
      Process.sleep(2)
      wait_for_change(pid, previous_state, waited + 2)
    else
      :ok
    end
  end

  defp fingerprint(state) do
    {
      state.phase,
      state.current_player_id,
      state.winning_bid,
      length(state.actions),
      length(state.played_cards),
      length(state.received_discards_from),
      length(state.trick_winning_cards),
      state.team_scores
    }
  end

  defp all_cards do
    for suit <- [:hearts, :diamonds, :clubs, :spades], value <- 1..13 do
      %Card{value: value, suit: suit}
    end
  end
end
