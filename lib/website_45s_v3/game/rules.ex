defmodule Website45sV3.Game.Rules do
  @moduledoc """
  Pure rules of the 45s card game: bidding validity, legal moves (including
  reneging), trick evaluation and round scoring.

  Everything in this module is a pure function of its inputs so the rules can
  be unit tested without starting a game process.
  """

  alias Website45sV3.Game.Card

  @suits [:hearts, :diamonds, :clubs, :spades]
  @bid_values [15, 20, 25, 30]
  @winning_score 120

  def suits, do: @suits
  def bid_values, do: @bid_values
  def winning_score, do: @winning_score

  @doc """
  Parses an untrusted `{bid, suit}` pair as sent by clients.

  The bid is a string (`"0"`, `"15"`, ...) and the suit an atom (a suit or
  `:pass`). Returns `{:ok, bid_integer, suit}` or `:error`.
  """
  def parse_bid(bid, suit) when is_binary(bid) do
    case Integer.parse(bid) do
      {0, ""} when suit == :pass -> {:ok, 0, :pass}
      {value, ""} when value in @bid_values and suit in @suits -> {:ok, value, suit}
      _ -> :error
    end
  end

  def parse_bid(_bid, _suit), do: :error

  @doc """
  Whether a bid is valid given the current highest bid and whether the dealer
  is bagged (forced to bid because everyone else passed).
  """
  def valid_bid?(0, :pass, _highest_bid, bagged?), do: not bagged?

  def valid_bid?(bid, suit, highest_bid, _bagged?)
      when bid in @bid_values and suit in @suits do
    bid > highest_bid
  end

  def valid_bid?(_bid, _suit, _highest_bid, _bagged?), do: false

  @doc """
  Returns the cards from `hand` that may legally be played when `card_led`
  led the trick.

  Follows suit rules of 45s: you must follow the led suit or trump, the ace
  of hearts always counts as trump, and the top trumps (5, jack, ace of
  hearts) may be reneged when a lower trump is led.
  """
  def legal_moves([], _card_led, _trump), do: []

  def legal_moves(hand, card_led, trump) do
    # Determine the suit led (the ace of hearts always counts as trump)
    suit_led =
      if card_led == %Card{suit: :hearts, value: 1} do
        trump
      else
        card_led.suit
      end

    # Get all of the cards that are of suit led
    legal_cards =
      Enum.filter(hand, fn card ->
        if suit_led == trump do
          cond do
            card.suit == trump -> true
            card.suit == :hearts and card.value == 1 -> true
            true -> false
          end
        else
          cond do
            card.suit == suit_led -> true
            card.suit == trump -> true
            card.suit == :hearts and card.value == 1 -> true
            true -> false
          end
        end
      end)

    # Check if all legal cards are of trump suit and if the suit led is not trump
    if Enum.all?(legal_cards, fn card -> card.suit == trump end) and suit_led != trump do
      hand
    else
      # Check if all legal cards are renegable
      if Enum.all?(legal_cards, &renegable?(&1, trump, card_led, suit_led)) do
        hand
      else
        case legal_cards do
          [] -> hand
          _ -> legal_cards
        end
      end
    end
  end

  defp renegable?(card, trump, card_led, suit_led) do
    renegable_cards = [
      %Card{suit: trump, value: 5},
      %Card{suit: trump, value: 11},
      %Card{suit: :hearts, value: 1}
    ]

    # If it's not less_than the card_led and it's in the renegable_cards list,
    # then it is renegable.
    not Card.less_than(card, card_led, suit_led, trump) and
      Enum.any?(renegable_cards, fn renegable_card ->
        renegable_card.suit == card.suit and renegable_card.value == card.value
      end)
  end

  @doc """
  Returns the winning `%{player_id: _, card: _}` entry of a trick.
  """
  def trick_winner([_ | _] = entries, suit_led, trump) do
    Enum.reduce(entries, fn entry, best ->
      if Card.less_than(best.card, entry.card, suit_led, trump), do: entry, else: best
    end)
  end

  @doc """
  The team a player belongs to. Players seated 1st and 3rd form team 1,
  players seated 2nd and 4th form team 2.
  """
  def team_for(player_ids, player_id) do
    case Enum.find_index(player_ids, &(&1 == player_id)) do
      index when index in [0, 2] -> :team1
      _ -> :team2
    end
  end

  def other_team(:team1), do: :team2
  def other_team(:team2), do: :team1

  @doc """
  Scores a completed round.

  The bidding team keeps its round points if it made the bid, otherwise it is
  set back by the bid amount. The other team always keeps its round points.
  Returns the score changes, the new totals, and the winning team if a team
  reached #{@winning_score}.
  """
  def score_round(round_scores, team_scores, {bid_amount, bid_player, _suit}, player_ids) do
    bid_team = team_for(player_ids, bid_player)
    other_team = other_team(bid_team)

    bid_team_points = Map.fetch!(round_scores, bid_team)

    bid_team_change =
      if bid_team_points >= bid_amount, do: bid_team_points, else: -bid_amount

    other_team_change = Map.fetch!(round_scores, other_team)

    new_team_scores =
      team_scores
      |> Map.update!(bid_team, &(&1 + bid_team_change))
      |> Map.update!(other_team, &(&1 + other_team_change))

    winning_team =
      cond do
        new_team_scores.team1 >= @winning_score -> :team1
        new_team_scores.team2 >= @winning_score -> :team2
        true -> nil
      end

    %{
      bid_team: bid_team,
      changes: %{bid_team => bid_team_change, other_team => other_team_change},
      team_scores: new_team_scores,
      winning_team: winning_team
    }
  end

  @doc """
  Parses an untrusted list of `"value_suit"` strings into cards.

  Returns `{:ok, cards}` (deduplicated) or `:error` if the payload is not a
  list of well-formed card strings. Never raises.
  """
  def parse_cards(card_strings) when is_list(card_strings) do
    card_strings
    |> Enum.reduce_while({:ok, []}, fn card_string, {:ok, acc} ->
      case Card.parse(card_string) do
        {:ok, card} -> {:cont, {:ok, [card | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, cards |> Enum.reverse() |> Enum.uniq()}
      :error -> :error
    end
  end

  def parse_cards(_), do: :error

  @doc """
  Validates a discard-phase "cards to keep" selection against a hand.

  Returns `{:ok, kept_cards}` or `:error`. A player must keep between 1 and
  5 cards, all of which must be in their hand.
  """
  def validate_discard(card_strings, hand) do
    with {:ok, cards} <- parse_cards(card_strings),
         true <- length(cards) in 1..5,
         true <- Enum.all?(cards, &(&1 in hand)) do
      {:ok, cards}
    else
      _ -> :error
    end
  end
end
