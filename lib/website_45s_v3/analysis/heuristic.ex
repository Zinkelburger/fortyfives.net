defmodule Website45sV3.Analysis.Heuristic do
  @moduledoc """
  The site bot's rules (`BotPlayer`, v2.0.1.31+, which keeps the ace of hearts as trump)
  on the analysis views of `Website45sV3.Analysis.CtPolicy`, for any seat count
  including the 4-seat partnership game. Port of Frank-45s-Opus `ct::HeuristicBot`.

  Fields read: bid `hand, high, seat, dealer, bagged`; keep `cards, trump, min_keep`
  (default 1); play `trump, legal, hist, trick_n, order`.
  """
  alias Website45sV3.Analysis.Slots

  @points %{5 => 12, 11 => 6, 1 => 4, 13 => 3, 12 => 2}
  # Elixir small-map order (C, D, H, S), for ties between suits
  @suit_tie [2, 1, 0, 3]

  @doc "`{value, suit}`, or `{0, nil}` to pass."
  def bid(v) do
    {sure, small} = Enum.reduce(v.hand, {{0, 0, 0, 0}, {0, 0, 0, 0}}, &count_card/2)

    best =
      Enum.reduce(tl(@suit_tie), hd(@suit_tie), fn s, b ->
        if elem(sure, s) > elem(sure, b), do: s, else: b
      end)

    est = elem(small, best) * 3 + elem(sure, best)
    b = if est >= 15, do: min(30, div(est, 5) * 5), else: 0
    choose_bid(v, b, best)
  end

  # Sure points per suit for honours (the ace of hearts counts in every
  # suit), and a count of the small cards.
  defp count_card(c, {sure, small}) do
    s = Slots.suit(c)

    cond do
      c == Slots.ace_hearts() ->
        {Enum.reduce(0..3, sure, &put_elem(&2, &1, elem(&2, &1) + 5)), small}

      pts = @points[Slots.value(c)] ->
        {put_elem(sure, s, elem(sure, s) + pts), small}

      true ->
        {sure, put_elem(small, s, elem(small, s) + 1)}
    end
  end

  defp choose_bid(%{bagged: true}, _b, best), do: {15, best}
  defp choose_bid(%{high: high}, b, best) when b > high, do: {b, best}

  defp choose_bid(v, b, best) do
    if v.seat == v.dealer and b > 0 and b == v.high, do: {b, best}, else: {0, nil}
  end

  @doc "The cards kept, in `cards` order: trumps and kings (at most 5), topped up to `min_keep` from the front."
  def keep(v) do
    min_keep = Map.get(v, :min_keep, 1)

    {kept, _} =
      Enum.reduce(v.cards, {[], 0}, fn c, {k, m} ->
        if m < 5 and (Slots.trump?(c, v.trump) or Slots.value(c) == 13),
          do: {[c | k], m + 1},
          else: {k, m}
      end)

    kept = Enum.reverse(kept)
    short = min_keep - length(kept)

    if short > 0 do
      extra = v.cards |> Enum.reject(&(&1 in kept)) |> Enum.take(short)
      Enum.filter(v.cards, &(&1 in kept or &1 in extra))
    else
      kept
    end
  end

  @doc "A legal card: its highest if that beats the table, else its lowest trump on a trump lead, else its lowest throw-away."
  def play(v) do
    t = v.trump
    cur = Enum.take(v.hist, -v.trick_n) |> Enum.map(&elem(&1, 1))
    sl = if v.trick_n > 0, do: Slots.suit_led(hd(cur), t), else: nil
    rank = &Slots.rank(t, sl, &1)
    mine = Enum.max_by(v.legal, rank)

    cond do
      cur == [] -> mine
      rank.(mine) >= rank.(Enum.max_by(cur, rank)) -> mine
      true -> cheapest(v, t, sl, rank)
    end
  end

  # Can't win the trick: the lowest trump on a trump lead, else the lowest
  # card that is neither trump nor the suit led, else the first in hand order.
  defp cheapest(v, t, sl, rank) do
    trumps = Enum.filter(v.legal, &Slots.trump?(&1, t))
    off = Enum.reject(v.legal, &(Slots.trump?(&1, t) or Slots.suit(&1) == sl))

    cond do
      sl == t and trumps != [] -> Enum.min_by(trumps, rank)
      off != [] -> Enum.min_by(off, rank)
      true -> Enum.find(v.order, &(&1 != nil and &1 in v.legal)) || Enum.min(v.legal)
    end
  end
end
