defmodule Website45sV3.Game.GameControllerTest do
  use ExUnit.Case
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.Card

  # Define some test setup or helpers if required. For example, if you need some typical card setups.

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
