defmodule Website45sV3.Analysis.Slots do
  @moduledoc """
  Card tables shared by the analysis policies and the heuristic, on integer card
  ids (`suit * 13 + value - 1`, suits H D C S = 0..3, ace of hearts = 0).

  `slot/2` places a card by its strength relative to trump (`SlotMap` in
  Frank-45s-Opus `approaches/dmc/policy.cpp`): the trump block is 5, J, A♥, A,
  K, Q, then pips strongest first (0..13); each other suit gets a 13-wide block
  in H D C S order, strongest first. `rank/3` is the engine's trick order.
  """
  import Bitwise

  @ace_hearts 0
  @no_led 4

  pip = fn s, v -> if s in [2, 3], do: 11 - v, else: v end

  offsuit = fn s, v ->
    cond do
      v in 2..10 -> pip.(s, v)
      v == 1 and s in [2, 3] -> 10
      true -> v
    end
  end

  trump_val = fn s, v ->
    cond do
      s == 0 and v == 1 -> 15
      v == 5 -> 17
      v == 11 -> 16
      v == 1 -> 14
      v == 13 -> 13
      v == 12 -> 12
      true -> pip.(s, v)
    end
  end

  trump? = fn c, t -> div(c, 13) == t or c == 0 end

  rank = fn t, l, c ->
    s = div(c, 13)
    v = rem(c, 13) + 1

    if trump?.(c, t) do
      2000 + trump_val.(s, v) * 4
    else
      if(s == l, do: 1000, else: 0) + offsuit.(s, v) * 4 + if(s == l, do: 0, else: s)
    end
  end

  ranks =
    for t <- 0..3 do
      for l <- 0..4 do
        0..51 |> Enum.map(&rank.(t, l, &1)) |> List.to_tuple()
      end
      |> List.to_tuple()
    end
    |> List.to_tuple()

  slot_table =
    for t <- 0..3 do
      pips =
        [2, 3, 4, 6, 7, 8, 9, 10]
        |> Enum.map(&(t * 13 + &1 - 1))
        |> Enum.sort_by(&rank.(t, t, &1), :desc)
        |> Enum.with_index(6)

      trump =
        [{t * 13 + 4, 0}, {t * 13 + 10, 1}, {@ace_hearts, 2}, {t * 13 + 12, 4}, {t * 13 + 11, 5}] ++
          if(t != 0, do: [{t * 13, 3}], else: []) ++ pips

      side =
        Enum.reject(0..3, &(&1 == t))
        |> Enum.with_index()
        |> Enum.flat_map(fn {s, b} ->
          (s * 13)..(s * 13 + 12)
          |> Enum.reject(&(&1 == @ace_hearts))
          |> Enum.sort_by(&rank.(t, s, &1), :desc)
          |> Enum.with_index(14 + b * 13)
        end)

      m = Map.new(trump ++ side)
      0..51 |> Enum.map(&Map.fetch!(m, &1)) |> List.to_tuple()
    end
    |> List.to_tuple()

  block_table =
    for t <- 0..3 do
      m = Map.new([{t, 0} | Enum.reject(0..3, &(&1 == t)) |> Enum.with_index(1)])
      0..3 |> Enum.map(&m[&1]) |> List.to_tuple()
    end
    |> List.to_tuple()

  @ranks ranks
  @slots slot_table
  @blocks block_table

  @doc "Input position (0..52) of card `c` with trump suit `t`."
  def slot(t, c), do: @slots |> elem(t) |> elem(c)

  @doc "Block (0 = trump, 1..3 the other suits in H D C S order) of suit `s` with trump `t`."
  def block(t, s), do: @blocks |> elem(t) |> elem(s)

  @doc "Trick order of card `c` with trump `t` and suit led `led` (0..3, or nil/4 before a lead). Higher wins."
  def rank(t, nil, c), do: rank(t, @no_led, c)
  def rank(t, led, c), do: @ranks |> elem(t) |> elem(led) |> elem(c)

  def ace_hearts, do: @ace_hearts
  def suit(c), do: div(c, 13)
  def value(c), do: rem(c, 13) + 1
  def trump?(c, t), do: div(c, 13) == t or c == @ace_hearts

  @doc "The suit a lead card calls for: the ace of hearts leads trump."
  def suit_led(@ace_hearts, t), do: t
  def suit_led(c, _t), do: div(c, 13)

  def bit(c), do: 1 <<< c
  def suit_mask(s), do: 0x1FFF <<< (s * 13)
  def trump_mask(t), do: suit_mask(t) ||| bit(@ace_hearts)
  def reneg_mask(t), do: bit(t * 13 + 4) ||| bit(t * 13 + 10) ||| bit(@ace_hearts)

  @doc "Bid value index: 15..30 -> 0..3."
  def bi(v), do: div(v, 5) - 3

  @doc "Bid value index with pass: 0 -> 0, 15..30 -> 1..4."
  def bi0(0), do: 0
  def bi0(v), do: div(v, 5) - 2

  @doc """
  What each seat has shown it cannot hold, from failing to follow: `%{seat => mask}`.
  `hist` is `[{seat, card}]` for this hand, oldest first, `n` cards per trick.
  """
  def voids(hist, n, t) do
    hist
    |> Enum.chunk_every(n)
    |> Enum.reduce(%{}, fn [{_, led} | rest], acc ->
      Enum.reduce(rest, acc, &add_void(&1, &2, led, t))
    end)
  end

  defp add_void({p, c}, acc, led, t) do
    case shown_void(c, led, t) do
      0 -> acc
      forb -> Map.update(acc, p, forb, &(&1 ||| forb))
    end
  end

  # The cards a seat has shown it lacks by playing `c` to a trick led by `led`.
  defp shown_void(c, led, t) do
    sl = suit_led(led, t)

    cond do
      band(suit_mask(sl) ||| trump_mask(t), bit(c)) != 0 -> 0
      sl != t -> band(suit_mask(sl), bnot(trump_mask(t)))
      true -> trump_lead_forbidden(t, sl, led)
    end
  end

  # Not following a trump lead shows no trumps but the top ones that outrank it.
  defp trump_lead_forbidden(t, sl, led) do
    led_rank = rank(t, sl, led)

    allowed =
      for r <- [t * 13 + 4, t * 13 + 10, @ace_hearts], rank(t, sl, r) > led_rank, reduce: 0 do
        a -> a ||| bit(r)
      end

    band(trump_mask(t), bnot(allowed))
  end

  @doc "Suits (0..3) in which a forbidden mask shows a void, ignoring the 5 and J (they may be held back)."
  def void_suits(forb) do
    for s <- 0..3,
        band(forb, suit_mask(s) &&& bnot(bit(s * 13 + 4)) &&& bnot(bit(s * 13 + 10))) != 0,
        do: s
  end
end
