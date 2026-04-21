defmodule Website45sV3.Game.GameControllerTest do
  use ExUnit.Case
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.Card

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

  test "start_game tracks permanent bots separately from autoplay players" do
    game_name = unique_game_name()

    {:ok, pid} =
      GameController.start_game(game_name, [
        {"Bot1", "bot_1"},
        {"Alice", "human_1"},
        {"Bob", "human_2"},
        {"Carol", "human_3"}
      ])

    on_exit(fn -> stop_game(pid) end)

    state = GameController.get_game_state(pid)

    assert state.seat_bots == MapSet.new(["bot_1"])
    assert state.auto_play_players == MapSet.new()
    assert state.all_bot_controlled_timer_ref == nil
  end

  test "all-bot games arm the all-bot-controlled timeout immediately" do
    game_name = unique_game_name()

    {:ok, pid} =
      GameController.start_game(game_name, [
        {"Bot1", "bot_1"},
        {"Bot2", "bot_2"},
        {"Bot3", "bot_3"},
        {"Bot4", "bot_4"}
      ])

    on_exit(fn -> stop_game(pid) end)

    state = GameController.get_game_state(pid)

    assert state.seat_bots == MapSet.new(["bot_1", "bot_2", "bot_3", "bot_4"])
    assert state.auto_play_players == MapSet.new()
    assert state.all_bot_controlled_timer_ref != nil
  end

  describe "get_legal_moves/3" do
    test "follow suit" do
      hand = [
        %Card{value: 2, suit: :spades},
        %Card{value: 1, suit: :hearts},
        %Card{value: 5, suit: :diamonds}
      ]

      card_led = %Card{value: 3, suit: :spades}
      trump = :spades

      result = GameController.get_legal_moves(hand, card_led, trump)
      expected_result = [%Card{value: 2, suit: :spades}, %Card{value: 1, suit: :hearts}]
      assert result == expected_result
    end

    test "play any card when no card of the led suit in hand" do
      hand = [
        %Card{value: 2, suit: :hearts},
        %Card{value: 1, suit: :clubs},
        %Card{value: 5, suit: :diamonds}
      ]

      card_led = %Card{value: 3, suit: :spades}
      trump = :spades

      result = GameController.get_legal_moves(hand, card_led, trump)
      assert result == hand
    end

    test "empty hand returns empty list" do
      hand = []
      card_led = %Card{value: 3, suit: :spades}
      trump = :diamonds

      result = GameController.get_legal_moves(hand, card_led, trump)
      assert result == []
    end

    test "reneg 5 when J led" do
      hand = [
        %Card{value: 5, suit: :spades},
        %Card{value: 1, suit: :clubs},
        %Card{value: 5, suit: :diamonds}
      ]

      card_led = %Card{value: 11, suit: :spades}
      trump = :spades

      result = GameController.get_legal_moves(hand, card_led, trump)
      expected_result = hand
      assert result == expected_result
    end
  end

  test "no reneg when 5 led" do
    hand = [
      %Card{value: 11, suit: :spades},
      %Card{value: 1, suit: :hearts},
      %Card{value: 5, suit: :diamonds}
    ]

    card_led = %Card{value: 5, suit: :spades}
    trump = :spades

    result = GameController.get_legal_moves(hand, card_led, trump)
    expected_result = [%Card{value: 11, suit: :spades}, %Card{value: 1, suit: :hearts}]
    assert result == expected_result
  end

  test "force ace of hearts when 5 led" do
    hand = [
      %Card{value: 11, suit: :diamonds},
      %Card{value: 1, suit: :hearts},
      %Card{value: 5, suit: :diamonds}
    ]

    card_led = %Card{value: 5, suit: :spades}
    trump = :spades

    result = GameController.get_legal_moves(hand, card_led, trump)
    expected_result = [%Card{value: 1, suit: :hearts}]
    assert result == expected_result
  end

  test "succesful reneg of J & 5 when A of H played" do
    hand = [
      %Card{value: 11, suit: :diamonds},
      %Card{value: 5, suit: :diamonds},
      %Card{value: 5, suit: :spades},
      %Card{value: 13, suit: :clubs}
    ]

    card_led = %Card{value: 1, suit: :hearts}
    trump = :diamonds

    result = GameController.get_legal_moves(hand, card_led, trump)
    expected_result = hand
    assert result == expected_result
  end

  test "offsuite can play offsuite or trump" do
    hand = [
      %Card{value: 1, suit: :diamonds},
      %Card{value: 13, suit: :diamonds},
      %Card{value: 5, suit: :spades},
      %Card{value: 13, suit: :clubs}
    ]

    card_led = %Card{value: 3, suit: :spades}
    trump = :diamonds

    result = GameController.get_legal_moves(hand, card_led, trump)

    expected_result = [
      %Card{value: 1, suit: :diamonds},
      %Card{value: 13, suit: :diamonds},
      %Card{value: 5, suit: :spades}
    ]

    assert result == expected_result
  end

  test "offsuite can play offsuite or trump 2" do
    hand = [
      %Card{value: 2, suit: :clubs},
      %Card{value: 11, suit: :clubs},
      %Card{value: 13, suit: :diamonds}
    ]

    card_led = %Card{value: 10, suit: :spades}
    trump = :clubs

    result = GameController.get_legal_moves(hand, card_led, trump)
    expected_result = hand
    assert result == expected_result
  end
end
