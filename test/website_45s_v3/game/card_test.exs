defmodule Website45sV3.Game.CardTest do
  use ExUnit.Case, async: true

  alias Website45sV3.Game.Card

  describe "parse/1" do
    test "parses well-formed card strings" do
      assert {:ok, %Card{value: 10, suit: :hearts}} = Card.parse("10_hearts")
      assert {:ok, %Card{value: 1, suit: :spades}} = Card.parse("1_spades")
      assert {:ok, %Card{value: 13, suit: :diamonds}} = Card.parse("13_diamonds")
    end

    test "round-trips with encode/1" do
      for value <- 1..13, suit <- [:hearts, :diamonds, :clubs, :spades] do
        card = Card.new(value, suit)
        assert {:ok, ^card} = card |> Card.encode() |> Card.parse()
      end
    end

    test "rejects malformed input without raising" do
      assert :error = Card.parse("garbage")
      assert :error = Card.parse("")
      assert :error = Card.parse("_")
      assert :error = Card.parse("x_hearts")
      assert :error = Card.parse("5_bogus")
      assert :error = Card.parse("0_hearts")
      assert :error = Card.parse("14_hearts")
      assert :error = Card.parse("5_hearts_extra")
      assert :error = Card.parse("5.5_hearts")
      assert :error = Card.parse(nil)
      assert :error = Card.parse(123)
      assert :error = Card.parse(%{})
    end
  end

  describe "less_than/4 trump ordering" do
    # In 45s the trump ranking from the top is:
    # 5 of trump > J of trump > A♥ > A of trump > K > Q > ...
    test "5 of trump is the highest trump" do
      five = %Card{value: 5, suit: :spades}
      jack = %Card{value: 11, suit: :spades}

      assert Card.less_than(jack, five, :spades, :spades)
      refute Card.less_than(five, jack, :spades, :spades)
    end

    test "jack of trump beats the ace of hearts" do
      jack = %Card{value: 11, suit: :spades}
      ace_hearts = %Card{value: 1, suit: :hearts}

      assert Card.less_than(ace_hearts, jack, :spades, :spades)
      refute Card.less_than(jack, ace_hearts, :spades, :spades)
    end

    test "ace of hearts beats the ace of trump" do
      ace_hearts = %Card{value: 1, suit: :hearts}
      ace_trump = %Card{value: 1, suit: :spades}

      assert Card.less_than(ace_trump, ace_hearts, :spades, :spades)
      refute Card.less_than(ace_hearts, ace_trump, :spades, :spades)
    end

    test "ace of hearts beats any non-trump card even when hearts are not trump" do
      ace_hearts = %Card{value: 1, suit: :hearts}
      king_spades = %Card{value: 13, suit: :spades}

      assert Card.less_than(king_spades, ace_hearts, :spades, :diamonds)
      refute Card.less_than(ace_hearts, king_spades, :spades, :diamonds)
    end

    test "any trump beats any card of the led suit" do
      two_trump = %Card{value: 2, suit: :diamonds}
      ace_led = %Card{value: 1, suit: :spades}

      assert Card.less_than(ace_led, two_trump, :spades, :diamonds)
      refute Card.less_than(two_trump, ace_led, :spades, :diamonds)
    end

    test "low trumps follow 'high in red, low in black'" do
      # red trump: 10 beats 2
      assert Card.less_than(
               %Card{value: 2, suit: :hearts},
               %Card{value: 10, suit: :hearts},
               :hearts,
               :hearts
             )

      # black trump: 2 beats 10
      assert Card.less_than(
               %Card{value: 10, suit: :spades},
               %Card{value: 2, suit: :spades},
               :spades,
               :spades
             )
    end
  end

  describe "less_than/4 offsuit ordering" do
    test "the led suit beats offsuit junk" do
      led_card = %Card{value: 3, suit: :spades}
      offsuit = %Card{value: 13, suit: :clubs}

      assert Card.less_than(offsuit, led_card, :spades, :hearts)
      refute Card.less_than(led_card, offsuit, :spades, :hearts)
    end

    test "red offsuit ranks high-to-low by face value" do
      ten = %Card{value: 10, suit: :diamonds}
      two = %Card{value: 2, suit: :diamonds}

      assert Card.less_than(two, ten, :diamonds, :spades)
    end

    test "black offsuit ranks 'low beats high' below the face cards" do
      two = %Card{value: 2, suit: :clubs}
      ten = %Card{value: 10, suit: :clubs}
      king = %Card{value: 13, suit: :clubs}

      assert Card.less_than(ten, two, :clubs, :hearts)
      assert Card.less_than(two, king, :clubs, :hearts)
    end
  end

  describe "card_to_filename/1" do
    test "encodes atoms and strings" do
      assert Card.card_to_filename({1, :hearts}) == "AH"
      assert Card.card_to_filename({13, :spades}) == "KS"
      assert Card.card_to_filename({10, "diamonds"}) == "10D"
    end

    test "returns :error for junk instead of raising" do
      assert Card.card_to_filename({5, "bogus"}) == :error
      assert Card.card_to_filename(:nonsense) == :error
    end
  end
end
