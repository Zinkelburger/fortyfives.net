defmodule Website45sV3.Game.BotPlayerTest do
  use ExUnit.Case, async: true

  alias Website45sV3.Game.BotPlayer
  alias Website45sV3.Game.Card

  defp discard(hand, trump) do
    BotPlayer.pick_discard(%{hands: %{"bot" => hand}, trump: trump}, "bot")
  end

  describe "pick_discard/2" do
    test "keeps the ace of hearts when another suit is trump" do
      hand = [
        Card.new(12, :clubs),
        Card.new(3, :hearts),
        Card.new(8, :clubs),
        Card.new(1, :hearts),
        Card.new(6, :diamonds)
      ]

      assert discard(hand, :clubs) == ["12_clubs", "8_clubs", "1_hearts"]
    end

    test "keeps the ace of hearts when it is the only trump" do
      hand = [
        Card.new(8, :clubs),
        Card.new(4, :clubs),
        Card.new(1, :hearts),
        Card.new(4, :hearts),
        Card.new(3, :spades)
      ]

      assert discard(hand, :diamonds) == ["1_hearts"]
    end

    test "keeps trumps and kings and throws the rest" do
      hand = [
        Card.new(13, :spades),
        Card.new(5, :diamonds),
        Card.new(2, :diamonds),
        Card.new(1, :spades),
        Card.new(9, :clubs)
      ]

      assert discard(hand, :diamonds) == ["13_spades", "5_diamonds", "2_diamonds"]
    end

    test "keeps the first card when nothing qualifies" do
      hand = [
        Card.new(9, :clubs),
        Card.new(8, :clubs),
        Card.new(7, :spades),
        Card.new(2, :spades),
        Card.new(3, :spades)
      ]

      assert discard(hand, :hearts) == ["9_clubs"]
    end

    test "keeps at most five cards" do
      hand = for v <- [5, 11, 13, 12, 2, 3, 4], do: Card.new(v, :hearts)
      hand = hand ++ [Card.new(1, :hearts)]

      assert length(discard(hand, :hearts)) == 5
    end
  end
end
