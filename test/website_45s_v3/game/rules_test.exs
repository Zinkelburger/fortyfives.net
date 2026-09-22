defmodule Website45sV3.Game.RulesTest do
  use ExUnit.Case, async: true

  alias Website45sV3.Game.Card
  alias Website45sV3.Game.Rules

  @players ["alice", "bob", "carol", "dave"]

  describe "legal_moves/3" do
    test "follow suit" do
      hand = [
        %Card{value: 2, suit: :spades},
        %Card{value: 1, suit: :hearts},
        %Card{value: 5, suit: :diamonds}
      ]

      card_led = %Card{value: 3, suit: :spades}
      trump = :spades

      result = Rules.legal_moves(hand, card_led, trump)
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

      assert Rules.legal_moves(hand, card_led, trump) == hand
    end

    test "empty hand returns empty list" do
      assert Rules.legal_moves([], %Card{value: 3, suit: :spades}, :diamonds) == []
    end

    test "reneg 5 when J led" do
      hand = [
        %Card{value: 5, suit: :spades},
        %Card{value: 1, suit: :clubs},
        %Card{value: 5, suit: :diamonds}
      ]

      card_led = %Card{value: 11, suit: :spades}
      trump = :spades

      assert Rules.legal_moves(hand, card_led, trump) == hand
    end

    test "no reneg when 5 led" do
      hand = [
        %Card{value: 11, suit: :spades},
        %Card{value: 1, suit: :hearts},
        %Card{value: 5, suit: :diamonds}
      ]

      card_led = %Card{value: 5, suit: :spades}
      trump = :spades

      expected_result = [%Card{value: 11, suit: :spades}, %Card{value: 1, suit: :hearts}]
      assert Rules.legal_moves(hand, card_led, trump) == expected_result
    end

    test "force ace of hearts when 5 led" do
      hand = [
        %Card{value: 11, suit: :diamonds},
        %Card{value: 1, suit: :hearts},
        %Card{value: 5, suit: :diamonds}
      ]

      card_led = %Card{value: 5, suit: :spades}
      trump = :spades

      assert Rules.legal_moves(hand, card_led, trump) == [%Card{value: 1, suit: :hearts}]
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

      assert Rules.legal_moves(hand, card_led, trump) == hand
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

      expected_result = [
        %Card{value: 1, suit: :diamonds},
        %Card{value: 13, suit: :diamonds},
        %Card{value: 5, suit: :spades}
      ]

      assert Rules.legal_moves(hand, card_led, trump) == expected_result
    end

    test "holding only trump when offsuit led allows the whole hand" do
      hand = [
        %Card{value: 2, suit: :clubs},
        %Card{value: 11, suit: :clubs},
        %Card{value: 13, suit: :diamonds}
      ]

      card_led = %Card{value: 10, suit: :spades}
      trump = :clubs

      assert Rules.legal_moves(hand, card_led, trump) == hand
    end

    test "trumps plus the ace of hearts never force a void player to trump" do
      # Void in diamonds: the only followers are a trump and the ace of
      # hearts (itself a trump), so the whole hand may be played.
      hand = [
        %Card{value: 1, suit: :hearts},
        %Card{value: 2, suit: :spades},
        %Card{value: 13, suit: :clubs},
        %Card{value: 9, suit: :clubs},
        %Card{value: 3, suit: :clubs}
      ]

      card_led = %Card{value: 9, suit: :diamonds}

      assert Rules.legal_moves(hand, card_led, :spades) == hand
    end

    test "the ace of hearts alone never forces a void player to trump" do
      hand = [
        %Card{value: 1, suit: :hearts},
        %Card{value: 13, suit: :clubs},
        %Card{value: 3, suit: :clubs}
      ]

      card_led = %Card{value: 9, suit: :diamonds}

      assert Rules.legal_moves(hand, card_led, :spades) == hand
    end

    test "hearts led when hearts are not trump: A♥ and trumps do not force a trump" do
      hand = [
        %Card{value: 1, suit: :hearts},
        %Card{value: 2, suit: :spades},
        %Card{value: 13, suit: :clubs}
      ]

      card_led = %Card{value: 9, suit: :hearts}

      assert Rules.legal_moves(hand, card_led, :spades) == hand
    end

    test "hearts led when hearts are not trump: a plain heart must still follow" do
      hand = [
        %Card{value: 1, suit: :hearts},
        %Card{value: 3, suit: :hearts},
        %Card{value: 2, suit: :spades},
        %Card{value: 13, suit: :clubs}
      ]

      card_led = %Card{value: 9, suit: :hearts}

      assert Rules.legal_moves(hand, card_led, :spades) == [
               %Card{value: 1, suit: :hearts},
               %Card{value: 3, suit: :hearts},
               %Card{value: 2, suit: :spades}
             ]
    end

    test "trump led still forces the ace of hearts and trumps" do
      hand = [
        %Card{value: 1, suit: :hearts},
        %Card{value: 2, suit: :spades},
        %Card{value: 13, suit: :clubs}
      ]

      card_led = %Card{value: 9, suit: :spades}

      assert Rules.legal_moves(hand, card_led, :spades) == [
               %Card{value: 1, suit: :hearts},
               %Card{value: 2, suit: :spades}
             ]
    end
  end

  describe "suit_led/2" do
    test "the ace of hearts leads trump" do
      assert Rules.suit_led(%Card{value: 1, suit: :hearts}, :clubs) == :clubs
      assert Rules.suit_led(%Card{value: 2, suit: :hearts}, :clubs) == :hearts
    end
  end

  describe "parse_bid/2" do
    test "accepts valid bids and passes" do
      assert {:ok, 0, :pass} = Rules.parse_bid("0", :pass)
      assert {:ok, 15, :hearts} = Rules.parse_bid("15", :hearts)
      assert {:ok, 30, :spades} = Rules.parse_bid("30", :spades)
    end

    test "rejects malformed or inconsistent bids" do
      assert :error = Rules.parse_bid("0", :hearts)
      assert :error = Rules.parse_bid("15", :pass)
      assert :error = Rules.parse_bid("17", :hearts)
      assert :error = Rules.parse_bid("abc", :hearts)
      assert :error = Rules.parse_bid("15", :bogus)
      assert :error = Rules.parse_bid("15 ", :hearts)
      assert :error = Rules.parse_bid(nil, :pass)
      assert :error = Rules.parse_bid(15, :hearts)
    end
  end

  describe "valid_bid?/5" do
    test "a pass is valid unless the dealer is bagged" do
      assert Rules.valid_bid?(0, :pass, 0, false)
      refute Rules.valid_bid?(0, :pass, 0, true)
      assert Rules.valid_bid?(0, :pass, 20, false, true)
      refute Rules.valid_bid?(0, :pass, 0, true, true)
    end

    test "a bid must exceed the current highest bid" do
      assert Rules.valid_bid?(15, :hearts, 0, false)
      assert Rules.valid_bid?(20, :hearts, 15, false)
      refute Rules.valid_bid?(15, :hearts, 15, false)
      refute Rules.valid_bid?(15, :hearts, 20, false)
    end

    test "a bagged dealer may bid 15" do
      assert Rules.valid_bid?(15, :clubs, 0, true)
      assert Rules.valid_bid?(15, :clubs, 0, true, true)
    end

    test "only the dealer may hold at the current high bid" do
      assert Rules.valid_bid?(20, :clubs, 20, false, true)
      refute Rules.valid_bid?(20, :clubs, 20, false, false)
      # holding is not a way to bid lower
      refute Rules.valid_bid?(15, :clubs, 20, false, true)
      # the dealer may still raise
      assert Rules.valid_bid?(25, :clubs, 20, false, true)
    end

    test "rejects bids outside the allowed values" do
      refute Rules.valid_bid?(17, :hearts, 0, false)
      refute Rules.valid_bid?(15, :pass, 0, false)
    end
  end

  describe "bid_allowed?/3" do
    test "matches valid_bid?/5 for every real bid, so the buttons match the game" do
      for bid <- Rules.bid_values(),
          highest <- [0 | Rules.bid_values()],
          dealer? <- [false, true] do
        assert Rules.bid_allowed?(bid, highest, dealer?) ==
                 Rules.valid_bid?(bid, :hearts, highest, false, dealer?),
               "bid #{bid} over #{highest}, dealer: #{dealer?}"
      end
    end

    test "the dealer may hold, nobody else may" do
      assert Rules.bid_allowed?(20, 20, true)
      refute Rules.bid_allowed?(20, 20, false)
      refute Rules.bid_allowed?(15, 20, true)
    end
  end

  describe "hold?/3" do
    test "is true only for the dealer matching a real bid" do
      assert Rules.hold?(20, 20, true)
      refute Rules.hold?(20, 20, false)
      refute Rules.hold?(25, 20, true)
      refute Rules.hold?(0, 0, true)
    end
  end

  describe "trick_winner/3" do
    test "highest card of the led suit wins when no trump is played" do
      entries = [
        %{player_id: "alice", card: %Card{value: 3, suit: :spades}},
        %{player_id: "bob", card: %Card{value: 13, suit: :spades}},
        %{player_id: "carol", card: %Card{value: 13, suit: :diamonds}},
        %{player_id: "dave", card: %Card{value: 12, suit: :spades}}
      ]

      winner = Rules.trick_winner(entries, :spades, :hearts)
      assert winner.player_id == "bob"
    end

    test "trump beats the led suit" do
      entries = [
        %{player_id: "alice", card: %Card{value: 13, suit: :spades}},
        %{player_id: "bob", card: %Card{value: 2, suit: :hearts}},
        %{player_id: "carol", card: %Card{value: 12, suit: :spades}},
        %{player_id: "dave", card: %Card{value: 4, suit: :diamonds}}
      ]

      winner = Rules.trick_winner(entries, :spades, :hearts)
      assert winner.player_id == "bob"
    end

    test "5 of trump beats jack of trump and ace of hearts" do
      entries = [
        %{player_id: "alice", card: %Card{value: 11, suit: :clubs}},
        %{player_id: "bob", card: %Card{value: 5, suit: :clubs}},
        %{player_id: "carol", card: %Card{value: 1, suit: :hearts}},
        %{player_id: "dave", card: %Card{value: 1, suit: :clubs}}
      ]

      winner = Rules.trick_winner(entries, :clubs, :clubs)
      assert winner.player_id == "bob"
    end

    test "ace of hearts wins over non-trump regardless of the led suit" do
      entries = [
        %{player_id: "alice", card: %Card{value: 13, suit: :spades}},
        %{player_id: "bob", card: %Card{value: 1, suit: :hearts}},
        %{player_id: "carol", card: %Card{value: 2, suit: :spades}},
        %{player_id: "dave", card: %Card{value: 12, suit: :spades}}
      ]

      winner = Rules.trick_winner(entries, :spades, :diamonds)
      assert winner.player_id == "bob"
    end

    test "the ace of hearts led wins against the led suit and offsuit" do
      entries = [
        %{player_id: "alice", card: %Card{value: 1, suit: :hearts}},
        %{player_id: "bob", card: %Card{value: 13, suit: :hearts}},
        %{player_id: "carol", card: %Card{value: 13, suit: :spades}},
        %{player_id: "dave", card: %Card{value: 2, suit: :clubs}}
      ]

      # Leading the ace of hearts leads trump (clubs): the 2 of clubs is a
      # trump too but ranks below the ace of hearts.
      suit_led = Rules.suit_led(%Card{value: 1, suit: :hearts}, :clubs)
      assert Rules.trick_winner(entries, suit_led, :clubs).player_id == "alice"
    end

    test "the winner is found regardless of play order" do
      winning = %{player_id: "carol", card: %Card{value: 5, suit: :hearts}}

      others = [
        %{player_id: "alice", card: %Card{value: 9, suit: :clubs}},
        %{player_id: "bob", card: %Card{value: 4, suit: :diamonds}},
        %{player_id: "dave", card: %Card{value: 13, suit: :hearts}}
      ]

      for entries <- permutations([winning | others]) do
        assert Rules.trick_winner(entries, :hearts, :hearts).player_id == "carol"
      end
    end
  end

  describe "best_trump/2" do
    test "picks the highest trump among trick winners regardless of the last suit led" do
      winners = [
        %{player_id: "alice", card: %Card{value: 13, suit: :spades}},
        %{player_id: "bob", card: %Card{value: 2, suit: :clubs}},
        %{player_id: "dave", card: %Card{value: 13, suit: :diamonds}},
        %{player_id: "carol", card: %Card{value: 1, suit: :diamonds}}
      ]

      assert Rules.best_trump(winners, :clubs).player_id == "bob"
      assert Rules.best_trump(winners, :diamonds).player_id == "carol"
      assert Rules.best_trump(winners, :spades).player_id == "alice"

      # The ace of hearts is a trump whatever the trump suit and outranks
      # every trump but the 5 and the jack.
      with_ace = [%{player_id: "erin", card: %Card{value: 1, suit: :hearts}} | winners]
      assert Rules.best_trump(with_ace, :clubs).player_id == "erin"
      assert Rules.best_trump(with_ace, :spades).player_id == "erin"
    end

    test "returns nil when no trump was played" do
      winners = [
        %{player_id: "alice", card: %Card{value: 13, suit: :spades}},
        %{player_id: "dave", card: %Card{value: 13, suit: :diamonds}}
      ]

      assert Rules.best_trump(winners, :clubs) == nil
    end
  end

  describe "team_for/2" do
    test "seats 1 and 3 are team 1, seats 2 and 4 are team 2" do
      assert Rules.team_for(@players, "alice") == :team1
      assert Rules.team_for(@players, "carol") == :team1
      assert Rules.team_for(@players, "bob") == :team2
      assert Rules.team_for(@players, "dave") == :team2
    end
  end

  describe "score_round/4" do
    test "the bidding team keeps its points when it makes the bid" do
      result =
        Rules.score_round(
          %{team1: 20, team2: 10},
          %{team1: 0, team2: 0},
          {15, "alice", :hearts},
          @players
        )

      assert result.bid_team == :team1
      assert result.changes == %{team1: 20, team2: 10}
      assert result.team_scores == %{team1: 20, team2: 10}
      assert result.winning_team == nil
    end

    test "the bidding team is set back by the bid when it fails" do
      result =
        Rules.score_round(
          %{team1: 10, team2: 20},
          %{team1: 50, team2: 30},
          {25, "alice", :hearts},
          @players
        )

      assert result.changes == %{team1: -25, team2: 20}
      assert result.team_scores == %{team1: 25, team2: 50}
      assert result.winning_team == nil
    end

    test "exactly making the bid counts as made" do
      result =
        Rules.score_round(
          %{team1: 5, team2: 15},
          %{team1: 0, team2: 0},
          {15, "bob", :hearts},
          @players
        )

      assert result.changes == %{team1: 5, team2: 15}
    end

    test "reaching 120 wins the game" do
      result =
        Rules.score_round(
          %{team1: 20, team2: 10},
          %{team1: 105, team2: 0},
          {15, "alice", :hearts},
          @players
        )

      assert result.team_scores.team1 == 125
      assert result.winning_team == :team1
    end

    test "the bidding team wins when both teams reach 120 in the same hand" do
      # Team 2 bid 20 and made 20; team 1 (non-bidders) took 10.
      result =
        Rules.score_round(
          %{team1: 10, team2: 20},
          %{team1: 115, team2: 100},
          {20, "bob", :hearts},
          @players
        )

      assert result.team_scores == %{team1: 125, team2: 120}
      assert result.winning_team == :team2

      # ...and vice versa when team 1 is the bidder.
      result =
        Rules.score_round(
          %{team1: 20, team2: 10},
          %{team1: 100, team2: 115},
          {20, "alice", :hearts},
          @players
        )

      assert result.winning_team == :team1
    end

    test "the non-bidding team can win by points" do
      result =
        Rules.score_round(
          %{team1: 5, team2: 25},
          %{team1: 0, team2: 100},
          {25, "alice", :hearts},
          @players
        )

      assert result.team_scores == %{team1: -25, team2: 125}
      assert result.winning_team == :team2
    end
  end

  describe "parse_cards/1 and validate_discard/2" do
    test "parses and deduplicates card strings" do
      assert {:ok, [%Card{value: 5, suit: :hearts}]} =
               Rules.parse_cards(["5_hearts", "5_hearts"])
    end

    test "rejects malformed payloads without raising" do
      assert :error = Rules.parse_cards(["garbage"])
      assert :error = Rules.parse_cards(["5_hearts", "junk"])
      assert :error = Rules.parse_cards([123])
      assert :error = Rules.parse_cards("not-a-list")
      assert :error = Rules.parse_cards(%{"cards" => []})
      assert :error = Rules.parse_cards(nil)
    end

    test "validates kept cards against the hand" do
      hand = [
        %Card{value: 5, suit: :hearts},
        %Card{value: 11, suit: :hearts},
        %Card{value: 2, suit: :clubs}
      ]

      assert {:ok, [%Card{value: 5, suit: :hearts}]} =
               Rules.validate_discard(["5_hearts"], hand)

      # must keep at least one card
      assert :error = Rules.validate_discard([], hand)
      # cannot keep a card that is not in the hand
      assert :error = Rules.validate_discard(["13_spades"], hand)
      # cannot keep more than five cards
      six = ["1_hearts", "2_hearts", "3_hearts", "4_hearts", "5_hearts", "6_hearts"]
      six_hand = Enum.map(six, fn s -> elem(Card.parse(s), 1) end)
      assert :error = Rules.validate_discard(six, six_hand)
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for head <- list, tail <- permutations(list -- [head]), do: [head | tail]
  end
end
