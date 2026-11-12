defmodule Website45sV3.Analysis.PolicyTest do
  # Differential test against the C++ policies and heuristic in Frank-45s-Opus. The fixtures
  # come from its tools/elixir_vectors.sh; see the header of each file for the line format.
  # Needs the weights (see test_helper.exs): a test tagged `weights: v` is skipped
  # when `<weights_dir>/v.bin` is missing, as in CI.
  use ExUnit.Case, async: true

  alias Website45sV3.Analysis.{CtPolicy, Heuristic, Net, TeamPolicy}

  @dir Path.expand("../../fixtures/analysis", __DIR__)
  @tol 2.0e-3

  for path <- Path.wildcard(Path.join(@dir, "vectors_*.txt")) |> Enum.sort() do
    variant = path |> Path.basename(".txt") |> String.trim_leading("vectors_")
    @path path
    @variant variant

    @tag weights: variant
    test "#{variant} policy and heuristic match C++" do
      policy = policy(@variant)
      assert policy, "no weights for #{@variant}"
      mod = if @variant == "team4", do: TeamPolicy, else: CtPolicy

      result =
        @path
        |> File.stream!()
        |> Stream.reject(&String.starts_with?(&1, "#"))
        |> Task.async_stream(&{&1, check(mod, policy, &1)}, timeout: :infinity)
        |> Enum.reduce(%{lines: 0, B: 0, K: 0, P: 0, failures: []}, fn {:ok, {line, res}}, acc ->
          {kind, problems} = res
          acc = acc |> Map.update!(:lines, &(&1 + 1)) |> Map.update!(kind, &(&1 + 1))

          if problems == [],
            do: acc,
            else: Map.update!(acc, :failures, &[{String.trim(line), problems} | &1])
        end)

      failures = Enum.reverse(result.failures)

      assert failures == [],
             "#{length(failures)} of #{result.lines} lines differ, first: #{inspect(Enum.take(failures, 3), limit: :infinity, printable_limit: 400)}"

      assert result.lines > 0
    end
  end

  @tag weights: "all"
  test "policy/1 caches shipped weights and returns nil for unknown variants" do
    p = Net.policy("team4")
    assert %{kind: :team, players: 4, nets: %{bid: _, pass: _, keep: _, play: _}} = p
    assert Net.policy("team4") === p
    assert %{kind: :ct, players: 2} = Net.policy("ct2")
    assert Net.policy("ct7") == nil
    assert Net.policy("../team4") == nil
  end

  defp policy(variant) do
    local = Path.join(@dir, variant <> ".bin")
    if File.exists?(local), do: Net.load_ct!(local), else: Net.policy(variant)
  end

  defp check(mod, policy, line) do
    [lhs, rhs] = line |> String.trim() |> String.split(" => ")
    [kind | f] = String.split(lhs, " ")
    [best, best_q, heur, all] = String.split(rhs, " ")
    best_q = String.to_float(best_q)

    case kind do
      "B" ->
        [n, seat, dealer, hand, high, hs, bag, score, bids] = f

        v = %{
          n: int(n),
          seat: int(seat),
          dealer: int(dealer),
          hand: ints(hand),
          high: int(high),
          high_seat: if(int(hs) < 0, do: nil, else: int(hs)),
          bagged: bag == "1",
          score: score |> ints() |> List.to_tuple(),
          bids: if(bids == "-", do: %{}, else: bids |> String.split(",") |> Map.new(&seat_bid/1))
        }

        expect = all |> String.split(",") |> Enum.map(&bid_q/1)

        {:B,
         compare(mod.bid_values(policy, v), expect, bid(best), best_q) ++
           same(:heuristic, Heuristic.bid(v), bid(heur))}

      "K" ->
        [n, seat, dealer, bidder, bid, trump, min_keep, bids, cards, score] = f

        v = %{
          n: int(n),
          seat: int(seat),
          dealer: int(dealer),
          bidder: int(bidder),
          bid: int(bid),
          trump: int(trump),
          min_keep: int(min_keep),
          bids: by_seat(bids),
          cards: ints(cards),
          score: score |> ints() |> List.to_tuple()
        }

        got = mod.keep_values(policy, v)
        expect = all |> String.split(",") |> Enum.map(&String.to_float/1)
        expect = Enum.zip(Enum.map(got, &elem(&1, 0)), expect)

        lengths =
          if length(got) == length(expect), do: [], else: [{:count, length(got), length(expect)}]

        {:K,
         lengths ++
           compare(got, expect, ints(best), best_q) ++
           same(:heuristic, Heuristic.keep(v), ints(heur))}

      "P" ->
        [
          n,
          seat,
          dealer,
          bidder,
          bid,
          trump,
          bids,
          kept,
          hand,
          order,
          legal,
          disc,
          hist,
          tn,
          tricks,
          score
        ] = f

        v = %{
          n: int(n),
          seat: int(seat),
          dealer: int(dealer),
          bidder: int(bidder),
          bid: int(bid),
          trump: int(trump),
          bids: by_seat(bids),
          kept: ints(kept),
          hand: ints(hand),
          order: order |> ints() |> Enum.map(&if(&1 < 0, do: nil, else: &1)),
          legal: ints(legal),
          discards: ints(disc),
          hist:
            if(hist == "-", do: [], else: hist |> String.split(",") |> Enum.map(&seat_card/1)),
          trick_n: int(tn),
          tricks: tricks |> ints() |> List.to_tuple(),
          score: score |> ints() |> List.to_tuple()
        }

        expect = all |> String.split(",") |> Enum.map(&seat_card/1)

        {:P,
         compare(mod.card_values(policy, v), expect, int(best), best_q) ++
           same(:heuristic, Heuristic.play(v), int(heur))}
    end
  end

  # Same actions in the same order, every value within @tol, and the same best action.
  defp compare(got, expect, best, best_q) do
    actions =
      if Enum.map(got, &elem(&1, 0)) == Enum.map(expect, &elem(&1, 0)),
        do: [],
        else: [{:actions, got, expect}]

    values =
      Enum.zip(got, expect)
      |> Enum.reject(fn {{_, a}, {_, b}} -> abs(a - b) < @tol end)
      |> Enum.map(fn {{x, a}, {_, b}} -> {:q, x, a, b} end)

    {b, q} = best(got)
    picked = if b == best and abs(q - best_q) < @tol, do: [], else: [{:best, b, q, best, best_q}]
    actions ++ values ++ picked
  end

  defp same(_, x, x), do: []
  defp same(what, got, want), do: [{what, got, want}]

  defp best([first | rest]),
    do: Enum.reduce(rest, first, fn {_, q} = x, {_, bq} = b -> if q > bq, do: x, else: b end)

  defp int(s), do: String.to_integer(s)
  defp ints("-"), do: []
  defp ints(s), do: s |> String.split(",") |> Enum.map(&int/1)
  defp bid(s), do: s |> String.split(":") |> bid_of()
  defp bid_of([v, s]), do: if(int(v) == 0, do: {0, nil}, else: {int(v), int(s)})

  defp bid_q(s),
    do: s |> String.split(":") |> then(fn [v, st, q] -> {bid_of([v, st]), String.to_float(q)} end)

  defp seat_bid(s),
    do: s |> String.split(":") |> then(fn [p, v, st] -> {int(p), bid_of([v, st])} end)

  defp by_seat(s),
    do: s |> String.split(",") |> Enum.with_index() |> Map.new(fn {b, p} -> {p, bid(b)} end)

  defp seat_card(s) do
    [a, b] = String.split(s, ":")
    {int(a), if(String.contains?(b, "."), do: String.to_float(b), else: int(b))}
  end
end
