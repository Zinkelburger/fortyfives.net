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

  describe "valid_bid?/4" do
    test "a pass is valid unless the dealer is bagged" do
      assert Rules.valid_bid?(0, :pass, 0, false)
      refute Rules.valid_bid?(0, :pass, 0, true)
    end

    test "a bid must exceed the current highest bid" do
      assert Rules.valid_bid?(15, :hearts, 0, false)
      assert Rules.valid_bid?(20, :hearts, 15, false)
      refute Rules.valid_bid?(15, :hearts, 15, false)
      refute Rules.valid_bid?(15, :hearts, 20, false)
    end

    test "a bagged dealer may bid 15" do
      assert Rules.valid_bid?(15, :clubs, 0, true)
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
