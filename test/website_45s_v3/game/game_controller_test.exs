defmodule Website45sV3.Game.GameControllerTest do
  use ExUnit.Case

  alias Website45sV3.Game.Card
  alias Website45sV3.Game.GameController

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
  end

  ## Game-driving helpers

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

    cond do
      done?.(state) ->
        state

      state.phase == "Bidding" and state.current_player_id != nil ->
        {highest, _, _} = state.winning_bid

        message =
          if highest == 0 and not state.bagged do
            {:player_bid, state.current_player_id, "15", :hearts}
          else
            bid = if state.bagged, do: {"15", :hearts}, else: {"0", :pass}
            {value, suit} = bid
            {:player_bid, state.current_player_id, value, suit}
          end

        send(pid, message)
        wait_for_change(pid, state)
        drive!(pid, done?, steps + 1)

      state.phase == "Discard" ->
        case state.player_ids -- state.received_discards_from do
          [] ->
            Process.sleep(2)
            drive!(pid, done?, steps + 1)

          [player | _] ->
            keep =
              state.hands[player]
              |> Enum.take(5)
              |> Enum.map(&Card.encode/1)

            send(pid, {:confirm_discard, player, keep})
            wait_for_change(pid, state)
            drive!(pid, done?, steps + 1)
        end

      state.phase == "Playing" and state.current_player_id != nil ->
        player = state.current_player_id
        hand = state.hands[player]
        legal = Map.get(state.legal_moves, player, hand)
        card = List.first(legal) || List.first(hand)

        send(pid, {:play_card, player, card})
        wait_for_change(pid, state)
        drive!(pid, done?, steps + 1)

      true ->
        # waiting on a game-internal transition timer
        Process.sleep(2)
        drive!(pid, done?, steps + 1)
    end
  end

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
