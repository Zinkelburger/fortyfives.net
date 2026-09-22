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
  Whether a bid is valid given the current highest bid, whether the dealer
  is bagged (forced to bid because everyone else passed) and whether the
  bidder is the dealer.

  Everyone must outbid the current high bid, except the dealer who bids
  last and may "hold": take the contract at the current high bid without
  raising it.
  """
  def valid_bid?(bid, suit, highest_bid, bagged?, dealer? \\ false)

  def valid_bid?(0, :pass, _highest_bid, bagged?, _dealer?), do: not bagged?

  def valid_bid?(bid, suit, highest_bid, _bagged?, dealer?)
      when bid in @bid_values and suit in @suits do
    bid_allowed?(bid, highest_bid, dealer?)
  end

  def valid_bid?(_bid, _suit, _highest_bid, _bagged?, _dealer?), do: false

  @doc """
  Whether a real bid (not a pass) of `bid` may be made over `highest_bid`:
  it must raise, or be the dealer holding. The single place the outbid/hold
  rule lives; the bidding buttons in the table view ask this too, so what a
  player can click is exactly what the game will accept.
  """
  def bid_allowed?(bid, highest_bid, dealer?) when is_integer(bid) do
    bid > highest_bid or hold?(bid, highest_bid, dealer?)
  end

  @doc """
  Whether the dealer may hold at `bid` given the current highest bid.
  """
  def hold?(bid, highest_bid, dealer?), do: dealer? and bid > 0 and bid == highest_bid

  @doc """
  Returns the cards from `hand` that may legally be played when `card_led`
  led the trick.

  Follows suit rules of 45s: you must follow the led suit or trump, the ace
  of hearts always counts as trump, and the top trumps (5, jack, ace of
  hearts) may be reneged when a lower trump is led. You are never forced to
  trump: a player void in the led suit may play anything.
  """
  def legal_moves([], _card_led, _trump), do: []

  def legal_moves(hand, card_led, trump) do
    suit_led = suit_led(card_led, trump)
    following = Enum.filter(hand, &can_follow?(&1, suit_led, trump))

    cond do
      following == [] -> hand
      suit_led != trump and Enum.all?(following, &Card.trump?(&1, trump)) -> hand
      Enum.all?(following, &renegable?(&1, trump, card_led, suit_led)) -> hand
      true -> following
    end
  end

  @doc """
  The suit a lead card establishes for the trick. The ace of hearts always
  counts as a trump, so leading it leads trump.
  """
  def suit_led(card_led, trump) do
    if Card.ace_of_hearts?(card_led), do: trump, else: card_led.suit
  end

  # A card follows the lead if it is of the led suit or is a trump.
  defp can_follow?(card, suit_led, trump) do
    card.suit == suit_led or Card.trump?(card, trump)
  end

  defp renegable?(card, trump, card_led, suit_led) do
    renegable_cards = [
      %Card{suit: trump, value: 5},
      %Card{suit: trump, value: 11},
      %Card{suit: :hearts, value: 1}
    ]

    # A top trump may be reneged only when it would beat the card led.
    card in renegable_cards and not Card.less_than(card, card_led, suit_led, trump)
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
  Returns the entry holding the highest trump among `entries`, or `nil` if
  no trump was played. Used for the "best trump" bonus at the end of a
  hand, which only trumps can earn regardless of what suit was led.
  """
  def best_trump(entries, trump) do
    entries
    |> Enum.filter(&Card.trump?(&1.card, trump))
    |> case do
      [] -> nil
      trumps -> trick_winner(trumps, trump, trump)
    end
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
  reached #{@winning_score}. If both teams reach it in the same hand the
  bidding team wins.
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

    %{
      bid_team: bid_team,
      changes: %{bid_team => bid_team_change, other_team => other_team_change},
      team_scores: new_team_scores,
      winning_team: winning_team(new_team_scores, bid_team)
    }
  end

  defp winning_team(%{team1: team1, team2: team2}, bid_team) do
    cond do
      team1 >= @winning_score and team2 >= @winning_score -> bid_team
      team1 >= @winning_score -> :team1
      team2 >= @winning_score -> :team2
      true -> nil
    end
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
