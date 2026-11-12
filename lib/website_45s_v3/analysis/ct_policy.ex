defmodule Website45sV3.Analysis.CtPolicy do
  @moduledoc """
  The cutthroat (2..6 players, each for themselves) value nets: Frank-45s-Opus
  `approaches/cutthroat/ct_policy.cpp`. Values are the acting player's score change
  minus the others' average, / 30. Seats are absolute (0..n-1); seat blocks in the
  features are relative to the acting seat.

  Views (lists oldest first):
    * bid: `%{n, seat, dealer, hand: [5 ids], bids: %{seat => {value, suit | nil}} (seats that have bid),
      high, high_seat (nil), bagged, score}`
    * keep: `%{n, seat, dealer, bidder, bid, trump, min_keep, bids, cards: [dealt 5, then the kitty for the bidder], score}`
    * play: `%{n, seat, dealer, bidder, bid, trump, bids, kept: [per seat], hand, order, legal, discards,
      hist: [{seat, card}], trick_n, tricks: {per seat}, score}`
  """
  alias Website45sV3.Analysis.{Net, Slots, TeamPolicy}

  @b_val 53
  @b_pos 57
  @b_high 63
  @b_hrel 68
  @b_pv 74
  @b_ps 99
  @b_tr 114
  @b_bag 118
  @b_hold 119
  @b_np 120
  @p_pos 52
  @p_high 58
  @p_hrel 63
  @p_pb 69
  @p_np 154
  @k_thrown 53
  @k_brel 106
  @k_bid 112
  @k_tr 116
  @k_drel 120
  @k_min 126
  @k_np 128
  @y_thrown 53
  @y_past 106
  @y_table 424
  @y_void 689
  @y_kept 709
  @y_bid 739
  @y_brel 743
  @y_drel 749
  @y_trk 755
  @y_tn 791
  @y_ti 797
  @y_tr 802
  @y_pb 806
  @y_win 836
  @y_np 842
  @y_act 847

  defp rel(p, seat, n), do: Integer.mod(p - seat, n)

  defp high_rel(%{high_seat: nil}), do: 0
  defp high_rel(v), do: rel(v.high_seat, v.seat, v.n)

  defp pos(v), do: rel(v.seat, rem(v.dealer + 1, v.n), v.n)

  @doc "Value of every legal bid: `[{{value, suit_or_nil}, q}]`, pass first (omitted when bagged)."
  def bid_values(p, v) do
    dealer? = v.seat == v.dealer
    pass = if v.bagged, do: [], else: [{{0, nil}, Net.eval(p.nets.pass, feat_pass(v))}]

    bids =
      for b <- [15, 20, 25, 30], s <- 0..3, b > v.high or (dealer? and b == v.high) do
        {{b, s}, Net.eval(p.nets.bid, feat_bid(v, b, s))}
      end

    pass ++ bids
  end

  defp prior(v, pos),
    do: for(k <- 0..(min(pos, 5) - 1)//1, do: {k, Map.fetch!(v.bids, rem(v.dealer + 1 + k, v.n))})

  defp feat_bid(v, b, t) do
    pos = pos(v)

    prior =
      for {k, {pv, ps}} <- prior(v, pos),
          f <- [@b_pv + k * 5 + Slots.bi0(pv), @b_ps + k * 3 + same_suit(pv, ps, t)],
          do: f

    Enum.map(v.hand, &Slots.slot(t, &1)) ++
      [
        @b_val + Slots.bi(b),
        @b_pos + pos,
        @b_high + Slots.bi0(v.high),
        @b_hrel + high_rel(v),
        @b_tr + t,
        @b_np + v.n - 2
      ] ++
      prior ++
      if(v.bagged, do: [@b_bag], else: []) ++
      if(b == v.high, do: [@b_hold], else: [])
  end

  defp same_suit(0, _, _), do: 0
  defp same_suit(_, t, t), do: 1
  defp same_suit(_, _, _), do: 2

  defp feat_pass(v) do
    pos = pos(v)

    prior =
      for {k, {pv, ps}} <- prior(v, pos) do
        @p_pb + k * 17 + if(pv > 0, do: 1 + Slots.bi(pv) * 4 + ps, else: 0)
      end

    v.hand ++
      [@p_pos + pos, @p_high + Slots.bi0(v.high), @p_hrel + high_rel(v), @p_np + v.n - 2] ++ prior
  end

  @doc "Value of every keep with `min_keep`..5 cards: `[{kept_ids, q}]`, kept in `cards` order."
  def keep_values(p, v) do
    net = p.nets.keep
    t = v.trump
    n = v.n

    state = [
      @k_brel + rel(v.bidder, v.seat, n),
      @k_bid + Slots.bi(v.bid),
      @k_tr + t,
      @k_drel + rel(v.dealer, v.seat, n),
      @k_min + min(1, v.min_keep - 1),
      @k_np + n - 2
    ]

    TeamPolicy.keeps(net, Net.base(net, state), v.cards, t, v.min_keep, 0, @k_thrown)
  end

  @doc "Value of every legal card: `[{card_id, q}]`, ascending card id."
  def card_values(p, v) do
    net = p.nets.play
    b = Net.base(net, feat_play(v))

    v.legal
    |> Enum.sort()
    |> Enum.map(fn c ->
      {c, Net.tail(net, Net.add_rows(b, net, [@y_act + Slots.slot(v.trump, c)]))}
    end)
  end

  defp feat_play(v) do
    t = v.trump
    n = v.n
    seat = v.seat
    done = length(v.hist) - v.trick_n
    {past, table} = Enum.split(v.hist, done)
    forb = Slots.voids(v.hist, n, t)
    at = fn tuple_or_list, r -> nth(tuple_or_list, rem(seat + r, n)) end

    win = winning_rel(table, t, seat, n)

    void_feats =
      for r <- 1..(n - 1), s <- Slots.void_suits(Map.get(forb, rem(seat + r, n), 0)) do
        @y_void + (r - 1) * 4 + Slots.block(t, s)
      end

    Enum.map(v.hand, &Slots.slot(t, &1)) ++
      Enum.map(v.discards, &(@y_thrown + Slots.slot(t, &1))) ++
      Enum.map(past, fn {s, c} -> @y_past + rel(s, seat, n) * 53 + Slots.slot(t, c) end) ++
      Enum.map(table, fn {s, c} -> @y_table + (rel(s, seat, n) - 1) * 53 + Slots.slot(t, c) end) ++
      void_feats ++
      for(r <- 0..(n - 1), do: @y_kept + r * 5 + at.(v.kept, r) - 1) ++
      [
        @y_bid + Slots.bi(v.bid),
        @y_brel + rel(v.bidder, seat, n),
        @y_drel + rel(v.dealer, seat, n)
      ] ++
      for(r <- 0..(n - 1), do: @y_trk + r * 6 + min(5, at.(v.tricks, r))) ++
      [@y_tn + v.trick_n, @y_ti + div(done, n), @y_tr + t] ++
      for(
        r <- 0..(n - 1),
        do: @y_pb + r * 5 + Slots.bi0(elem(Map.get(v.bids, rem(seat + r, n), {0, nil}), 0))
      ) ++
      [@y_win + win, @y_np + n - 2]
  end

  defp nth(t, i) when is_tuple(t), do: elem(t, i)
  defp nth(l, i) when is_list(l), do: Enum.at(l, i)

  # The seat (relative to `seat`) whose card is winning the trick so far; 0 if none.
  defp winning_rel([], _t, _seat, _n), do: 0

  defp winning_rel([{_, led} | _] = table, t, seat, n) do
    sl = Slots.suit_led(led, t)

    {s, _} =
      Enum.reduce(table, fn {_, c} = x, {_, bc} = b ->
        if Slots.rank(t, sl, c) > Slots.rank(t, sl, bc), do: x, else: b
      end)

    rel(s, seat, n)
  end
end
