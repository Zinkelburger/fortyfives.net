defmodule Website45sV3.Analysis.TeamPolicy do
  @moduledoc """
  The partnership (2 v 2) value nets: Frank-45s-Opus `approaches/dmc/policy.cpp`.
  Each function returns the value of every legal action, in expected net points / 30
  for the acting seat's team. Seats are 0..3, team = seat &&& 1.

  Views:
    * bid: `%{seat, dealer, hand: [ids], bids: %{seat => {value, suit | nil}}, high, high_seat (nil), bagged, score: {team0, team1}}`
    * keep: `%{seat, dealer, bidder, bid, trump, cards: [dealt 5, then the kitty for the bidder], score}`
    * play: `%{seat, dealer, bidder, bid, trump, bids, kept: [per seat], hand, legal, discards,
      hist: [{seat, card}], trick_n, tricks: {team0, team1}, score}`
  """
  import Bitwise
  alias Website45sV3.Analysis.{Net, Slots}

  @sb 36
  @b_val 53
  @b_pos 57
  @b_high 61
  @b_hrel 66
  @b_pv 69
  @b_ps 84
  @b_tr 93
  @b_bag 97
  @b_hold 98
  @b_sc 99
  @p_pos 52
  @p_high 56
  @p_hrel 61
  @p_pb 64
  @p_sc 115
  @k_thrown 53
  @k_brel 106
  @k_bid 110
  @k_tr 114
  @k_drel 118
  @k_sc 122
  @y_thrown 53
  @y_past 106
  @y_table 318
  @y_void 477
  @y_kept 489
  @y_bid 509
  @y_brel 513
  @y_drel 517
  @y_tm 521
  @y_tt 526
  @y_tn 531
  @y_ti 535
  @y_tr 540
  @y_pb 544
  @y_act 564
  @y_sc 617

  defp bucket(s), do: div(min(max(s, -60), 119) + 60, 5)
  defp team(seat), do: band(seat, 1)
  defp rel(a, b), do: band(a - b, 3)

  defp score_feats(p, view, off) do
    if p.use_score do
      m = team(view.seat)
      [off + bucket(elem(view.score, m)), off + @sb + bucket(elem(view.score, 1 - m))]
    else
      []
    end
  end

  defp high_rel(%{high_seat: nil}), do: 0
  defp high_rel(v), do: if(team(v.high_seat) == team(v.seat), do: 1, else: 2)

  @doc "Value of every legal bid: `[{{value, suit_or_nil}, q}]`, pass first (omitted when bagged)."
  def bid_values(p, v) do
    dealer? = v.seat == v.dealer
    pass = if v.bagged, do: [], else: [{{0, nil}, Net.eval(p.nets.pass, feat_pass(p, v))}]

    bids =
      for b <- [15, 20, 25, 30], s <- 0..3, b > v.high or (dealer? and b == v.high) do
        {{b, s}, Net.eval(p.nets.bid, feat_bid(p, v, b, s))}
      end

    pass ++ bids
  end

  defp feat_bid(p, v, b, t) do
    pos = band(v.seat - v.dealer - 1, 3)

    prior =
      for k <- 0..(pos - 1)//1,
          {pv, ps} = Map.fetch!(v.bids, band(v.dealer + 1 + k, 3)),
          f <- [@b_pv + k * 5 + Slots.bi0(pv), @b_ps + k * 3 + same_suit(pv, ps, t)],
          do: f

    Enum.map(v.hand, &Slots.slot(t, &1)) ++
      [
        @b_val + Slots.bi(b),
        @b_pos + pos,
        @b_high + Slots.bi0(v.high),
        @b_hrel + high_rel(v),
        @b_tr + t
      ] ++
      prior ++
      if(v.bagged, do: [@b_bag], else: []) ++
      if(b == v.high, do: [@b_hold], else: []) ++ score_feats(p, v, @b_sc)
  end

  defp same_suit(0, _, _), do: 0
  defp same_suit(_, t, t), do: 1
  defp same_suit(_, _, _), do: 2

  defp feat_pass(p, v) do
    pos = band(v.seat - v.dealer - 1, 3)

    prior =
      for k <- 0..(pos - 1)//1 do
        {pv, ps} = Map.fetch!(v.bids, band(v.dealer + 1 + k, 3))
        @p_pb + k * 17 + if(pv > 0, do: 1 + Slots.bi(pv) * 4 + ps, else: 0)
      end

    v.hand ++
      [@p_pos + pos, @p_high + Slots.bi0(v.high), @p_hrel + high_rel(v)] ++
      prior ++ score_feats(p, v, @p_sc)
  end

  @doc "Value of every keep (1..5 cards): `[{kept_ids, q}]`, kept in `cards` order."
  def keep_values(p, v) do
    net = p.nets.keep
    t = v.trump

    state =
      [
        @k_brel + rel(v.bidder, v.seat),
        @k_bid + Slots.bi(v.bid),
        @k_tr + t,
        @k_drel + rel(v.dealer, v.seat)
      ] ++
        score_feats(p, v, @k_sc)

    keeps(net, Net.base(net, state), v.cards, t, 1, 0, @k_thrown)
  end

  @doc false
  # Every subset of `cards` with min..5 cards, in C++ order (bitmask over positions, ascending).
  def keeps(net, base, cards, t, min, kept_off, thrown_off) do
    rows = Enum.map(cards, &{&1, kept_off + Slots.slot(t, &1), thrown_off + Slots.slot(t, &1)})
    # Depth first from the last card, thrown before kept: ascending bitmask order, and each
    # partial sum of W1 rows is shared by every subset below it.
    subsets(Enum.reverse(rows), base, net, 0, [], min, length(rows))
  end

  defp subsets([], acc, net, _count, kept, _min, _left), do: [{kept, Net.tail(net, acc)}]

  defp subsets([{card, k, th} | rest], acc, net, count, kept, min, left) do
    left = left - 1

    thrown =
      if count + left >= min,
        do: subsets(rest, Net.add_rows(acc, net, [th]), net, count, kept, min, left),
        else: []

    keep =
      if count < 5,
        do: subsets(rest, Net.add_rows(acc, net, [k]), net, count + 1, [card | kept], min, left),
        else: []

    thrown ++ keep
  end

  @doc "Value of every legal card: `[{card_id, q}]`, ascending card id."
  def card_values(p, v) do
    net = p.nets.play
    b = Net.base(net, feat_play(p, v))

    v.legal
    |> Enum.sort()
    |> Enum.map(fn c ->
      {c, Net.tail(net, Net.add_rows(b, net, [@y_act + Slots.slot(v.trump, c)]))}
    end)
  end

  defp feat_play(p, v) do
    t = v.trump
    done = length(v.hist) - v.trick_n
    {past, table} = Enum.split(v.hist, done)
    m = team(v.seat)
    forb = Slots.voids(v.hist, 4, t)

    void_feats =
      for r <- 1..3, s <- Slots.void_suits(Map.get(forb, band(v.seat + r, 3), 0)) do
        @y_void + (r - 1) * 4 + Slots.block(t, s)
      end

    Enum.map(v.hand, &Slots.slot(t, &1)) ++
      Enum.map(v.discards, &(@y_thrown + Slots.slot(t, &1))) ++
      Enum.map(past, fn {s, c} -> @y_past + rel(s, v.seat) * 53 + Slots.slot(t, c) end) ++
      Enum.map(table, fn {s, c} -> @y_table + (rel(s, v.seat) - 1) * 53 + Slots.slot(t, c) end) ++
      void_feats ++
      for(r <- 0..3, do: @y_kept + r * 5 + Enum.at(v.kept, band(v.seat + r, 3)) - 1) ++
      [
        @y_bid + Slots.bi(v.bid),
        @y_brel + rel(v.bidder, v.seat),
        @y_drel + rel(v.dealer, v.seat),
        @y_tm + min(elem(v.tricks, m), 4),
        @y_tt + min(elem(v.tricks, 1 - m), 4),
        @y_tn + v.trick_n,
        @y_ti + div(done, 4),
        @y_tr + t
      ] ++
      for(
        r <- 0..3,
        do: @y_pb + r * 5 + Slots.bi0(elem(Map.get(v.bids, band(v.seat + r, 3), {0, nil}), 0))
      ) ++
      score_feats(p, v, @y_sc)
  end
end
