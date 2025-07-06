defmodule Website45sV3.Game.BotPlayer do
  @moduledoc """
  Basic automated player used when a participant is idle.
  The functions here return moves for the various phases of the game.
  """
  alias Website45sV3.Game.Card

  @doc """
  Returns a bid value and suit based on the player's hand. The logic mirrors the
  heuristics used by the selenium bot defined in `python/tbot.py`.
  """
  def pick_bid(state, player_id) do
    hand = Map.get(state.hands, player_id, [])

    {bid, suit} = evaluate_hand_bid(hand)
    highest_bid = elem(state.winning_bid, 0)

    {bid, suit} =
      cond do
        state.bagged && player_id == state.current_player_id ->
          {15, suit}
        bid > highest_bid ->
          {bid, suit}
        true ->
          {0, :pass}
      end

    bid_suit = if bid == 0, do: :pass, else: suit
    {bid, bid_suit}
  end

  @doc """
  Returns a list of card strings representing the cards a bot keeps during the
  discard phase.

  The bot keeps any trump cards or kings (value == 13). If none are present, it
  keeps exactly the first card from its hand. In all cases no more than five
  cards are returned. Each card is encoded as "value_suit".
  """
  def pick_discard(state, player_id) do
    hand  = Map.get(state.hands, player_id, [])
    trump = state.trump

    # 1) Filter for all trumps or kings
    kept =
      Enum.filter(hand, fn %Card{suit: suit, value: value} ->
        suit == trump or value == 13
      end)

    # 2) If none, keep exactly the first card; otherwise keep the filtered ones
    kept =
      case kept do
        []    -> [hd(hand)]    # keep just one
        cards -> cards
      end

    # 3) Never keep more than five
    kept = Enum.take(kept, 5)

    # 4) (Optional) Compute discards if you need them
    discarded = hand -- kept

    # 5) Return just the kept cards encoded as strings
    Enum.map(kept, &format_card/1)

    # — or, if you did want to return both:
    # {Enum.map(kept, &format_card/1), Enum.map(discarded, &format_card/1)}
  end


  @doc """
  Chooses a card to play from the player's legal moves. If no legal moves are
  provided, the first card in their hand is selected.
  """
  def pick_card(state, player_id) do
    hand = Map.get(state.hands, player_id, [])
    legal = Map.get(state.legal_moves, player_id, hand)
    current_cards = Enum.map(state.played_cards, & &1.card)

    evaluate_hand_play(state.suit_led, legal, current_cards, elem(state.winning_bid, 0), state.trump) ||
      List.first(legal) || List.first(hand)
  end

  defp format_card(%Card{value: value, suit: suit}) do
    "#{value}_#{Atom.to_string(suit)}"
  end

  # --- Heuristic helpers ---

  defp evaluate_hand_bid(player_hand) do
    suits = [:hearts, :diamonds, :clubs, :spades]

    small_cards = Map.new(suits, fn s -> {s, 0} end)
    sure_points = Map.new(suits, fn s -> {s, 0} end)

    face_card_points = %{5 => 12, 11 => 6, 1 => 4, 13 => 3, 12 => 2}

    {small_cards, sure_points} =
      Enum.reduce(player_hand, {small_cards, sure_points}, fn card, {sm, sp} ->
        cond do
          Card.is_ace_of_hearts?(card) ->
            {sm,
             Enum.reduce(suits, sp, fn suit, acc -> Map.update!(acc, suit, &(&1 + 5)) end)}

          Map.has_key?(face_card_points, card.value) ->
            {sm, Map.update!(sp, card.suit, &(&1 + face_card_points[card.value]))}

          true ->
            {Map.update!(sm, card.suit, &(&1 + 1)), sp}
        end
      end)

    {max_suit, _} = Enum.max_by(sure_points, fn {_suit, val} -> val end)
    estimated_value = Map.get(small_cards, max_suit) * 3 + Map.get(sure_points, max_suit)
    bid_value = if estimated_value >= 15, do: div(estimated_value, 5) * 5, else: 0

    {bid_value, max_suit}
  end

  defp get_max_card([], _suit_led, _trump), do: nil
  defp get_max_card([card | rest], suit_led, trump) do
    Enum.reduce(rest, card, fn c, acc ->
      if Card.less_than(acc, c, suit_led, trump), do: c, else: acc
    end)
  end

  defp get_min_card([], _suit_led, _trump), do: nil
  defp get_min_card([card | rest], suit_led, trump) do
    Enum.reduce(rest, card, fn c, acc ->
      if Card.less_than(c, acc, suit_led, trump), do: c, else: acc
    end)
  end

  defp evaluate_hand_play(_suit_led, [], _current_cards, _bid_amount, _trump), do: nil
  defp evaluate_hand_play(suit_led, player_hand, current_cards, _bid_amount, trump) do
    max_card = get_max_card(current_cards, suit_led, trump)
    players_max_card = get_max_card(player_hand, suit_led, trump)

    players_lowest_offsuite =
      player_hand
      |> Enum.filter(fn c -> c.suit != suit_led and c.suit != trump end)
      |> get_min_card(suit_led, trump)

    players_worst_trump =
      if Enum.any?(player_hand, fn c -> c.suit == trump end) do
        player_hand
        |> Enum.filter(&(&1.suit == trump))
        |> get_min_card(suit_led, trump)
      else
        nil
      end

    cond do
      max_card == nil -> players_max_card
      not Card.less_than(players_max_card, max_card, suit_led, trump) -> players_max_card
      suit_led == trump and players_worst_trump != nil -> players_worst_trump
      players_lowest_offsuite != nil -> players_lowest_offsuite
      true -> List.first(player_hand)
    end
  end
end
