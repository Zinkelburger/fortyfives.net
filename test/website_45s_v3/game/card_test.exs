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

  describe "less_than/4 ace of hearts" do
    test "when hearts are trump the ace of hearts sits below the jack and above the ace of trump" do
      ace_hearts = %Card{value: 1, suit: :hearts}
      jack = %Card{value: 11, suit: :hearts}
      five = %Card{value: 5, suit: :hearts}
      king = %Card{value: 13, suit: :hearts}

      assert Card.less_than(ace_hearts, jack, :hearts, :hearts)
      assert Card.less_than(ace_hearts, five, :hearts, :hearts)
      assert Card.less_than(king, ace_hearts, :hearts, :hearts)
      refute Card.less_than(ace_hearts, king, :hearts, :hearts)
    end

    test "the ace of hearts is a trump even when hearts are led and not trump" do
      ace_hearts = %Card{value: 1, suit: :hearts}
      king_hearts = %Card{value: 13, suit: :hearts}
      two_trump = %Card{value: 2, suit: :clubs}

      assert Card.less_than(king_hearts, ace_hearts, :hearts, :clubs)
      assert Card.less_than(two_trump, ace_hearts, :hearts, :clubs)
      assert Card.trump?(ace_hearts, :clubs)
      refute Card.trump?(king_hearts, :clubs)
    end
  end

  describe "less_than/4 offsuit ordering" do
    test "a black off-suit ace ranks between the jack and the 2" do
      ace = %Card{value: 1, suit: :clubs}
      jack = %Card{value: 11, suit: :clubs}
      two = %Card{value: 2, suit: :clubs}

      assert Card.less_than(ace, jack, :clubs, :hearts)
      assert Card.less_than(two, ace, :clubs, :hearts)
    end

    test "a red off-suit ace is the lowest card of its suit" do
      ace = %Card{value: 1, suit: :diamonds}
      two = %Card{value: 2, suit: :diamonds}

      assert Card.less_than(ace, two, :diamonds, :spades)
      refute Card.less_than(two, ace, :diamonds, :spades)
    end

    test "cards that can neither win nor follow are still totally ordered" do
      # Neither card is trump (spades) nor of the led suit (hearts).
      king_clubs = %Card{value: 13, suit: :clubs}
      two_diamonds = %Card{value: 2, suit: :diamonds}
      two_clubs = %Card{value: 2, suit: :clubs}

      assert Card.less_than(two_diamonds, king_clubs, :hearts, :spades)
      refute Card.less_than(king_clubs, two_diamonds, :hearts, :spades)

      # Equal off-suit ranks (2♦ counts 2, 9♣ counts 2) are broken by suit,
      # never both ways.
      nine_clubs = %Card{value: 9, suit: :clubs}
      assert Card.less_than(two_diamonds, nine_clubs, :hearts, :spades)
      refute Card.less_than(nine_clubs, two_diamonds, :hearts, :spades)

      # and a card is never less than itself
      refute Card.less_than(two_clubs, two_clubs, :hearts, :spades)
    end

    test "is antisymmetric over every pair of distinct cards, including when leading" do
      cards =
        for suit <- [:hearts, :diamonds, :clubs, :spades],
            value <- 1..13,
            do: Card.new(value, suit)

      for suit_led <- [nil, :hearts, :clubs], trump <- [:spades, :hearts] do
        for a <- cards, b <- cards, a != b do
          assert Card.less_than(a, b, suit_led, trump) != Card.less_than(b, a, suit_led, trump),
                 "#{Card.to_string(a)} vs #{Card.to_string(b)} (led #{suit_led}, trump #{trump})"
        end
      end
    end

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

  describe "to_string/1 and ace_of_hearts?/1" do
    test "names cards" do
      assert Card.to_string(%Card{value: 5, suit: :hearts}) == "5 of Hearts"
      assert Card.to_string(%Card{value: 1, suit: :spades}) == "Ace of Spades"
      assert Card.to_string(%Card{value: 12, suit: :clubs}) == "Queen of Clubs"
    end

    test "recognises the ace of hearts in both shapes" do
      assert Card.ace_of_hearts?(%Card{value: 1, suit: :hearts})
      assert Card.ace_of_hearts?({:hearts, 1})
      refute Card.ace_of_hearts?(%Card{value: 1, suit: :spades})
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
