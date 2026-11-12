defmodule Website45sV3.Analysis.EngineTest do
  # Replays hands played by the research engine (Frank-45s-Opus,
  # tools/elixir_vectors.sh) and checks every legal-move set, the draw, each
  # trick winner and the scoring against it.
  use ExUnit.Case, async: true

  alias Website45sV3.Analysis.Engine
  alias Website45sV3.Analysis.Engine.Setup
  alias Website45sV3.Analysis.Variant

  @dir Path.expand("../../fixtures/analysis", __DIR__)

  for id <- Variant.ids() do
    @id id
    test "#{id}: hands replay exactly as the research engine played them" do
      variant = Variant.get!(@id)
      hands = parse(Path.join(@dir, "trace_#{@id}.txt"))
      assert length(hands) >= 250

      checked = Enum.count(hands, &check_hand(variant, &1))
      # Hands where a bagged dealer bid over 15 (the site allows only 15) are skipped.
      assert checked >= length(hands) * 0.6
    end
  end

  defp ints("-"), do: []
  defp ints(s), do: s |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)

  defp bid("0:-1"), do: {0, nil}

  defp bid(s) do
    [v, t] = s |> String.split(":") |> Enum.map(&String.to_integer/1)
    {v, t}
  end

  defp parse(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&String.split(&1, " "))
    |> Enum.chunk_while(
      [],
      fn
        ["H" | _] = line, [] -> {:cont, [line]}
        ["H" | _] = line, acc -> {:cont, Enum.reverse(acc), [line]}
        line, acc -> {:cont, [line | acc]}
      end,
      fn acc -> {:cont, Enum.reverse(acc), []} end
    )
  end

  defp check_hand(variant, [["H", _hand, dealer, scores, deck] | lines]) do
    setup = %Setup{
      variant: variant,
      dealer: String.to_integer(dealer),
      scores: ints(scores),
      decks: %{1 => ints(deck)}
    }

    lines
    |> Enum.reduce_while(Engine.new(setup), fn line, state ->
      case step(state, line) do
        :skip -> {:halt, :skip}
        state -> {:cont, state}
      end
    end)
    |> case do
      :skip ->
        false

      state ->
        assert state.phase == :game_over == Enum.any?(lines, &(hd(&1) == "G"))
        true
    end
  end

  defp step(state, ["B", seat, legal, chosen]) do
    seat = String.to_integer(seat)
    assert Engine.to_act(state) == [seat]
    theirs = legal |> String.split(",") |> Enum.map(&bid/1)
    chosen = bid(chosen)

    if Engine.bagged?(state) do
      assert Engine.legal_bids(state) == for(s <- 0..3, do: {15, s})
      if elem(chosen, 0) != 15, do: throw(:skip)
    else
      assert Engine.legal_bids(state) == theirs
    end

    apply!(state, {:bid, seat, chosen})
  catch
    :skip -> :skip
  end

  defp step(state, ["K", seat, cards, kept]) do
    seat = String.to_integer(seat)
    assert state.phase == :discard
    assert state.hands[seat] == ints(cards)
    apply!(state, {:keep, seat, ints(kept)})
  end

  defp step(state, ["F" | orders]) do
    assert state.phase == :playing
    assert Enum.map(0..(state.variant.n - 1), &state.order[&1]) == Enum.map(orders, &ints/1)
    state
  end

  defp step(state, ["P", seat, legal, card]) do
    seat = String.to_integer(seat)
    assert Engine.to_act(state) == [seat]
    assert Enum.sort(Engine.legal_cards(state, seat)) == ints(legal)
    apply!(state, {:play, seat, String.to_integer(card)})
  end

  defp step(state, ["T", winner]) do
    assert {_, w} = state.last_trick
    assert w == String.to_integer(winner)
    state
  end

  defp step(state, ["R", bidder, bid, trump, bonus, tricks, points, change]) do
    r = state.result
    assert r.bidder == String.to_integer(bidder)
    assert r.bid == String.to_integer(bid)
    assert r.trump == String.to_integer(trump)
    assert (r.bonus_seat || -1) == String.to_integer(bonus)
    assert r.tricks == ints(tricks)
    assert r.points == ints(points)
    assert r.change == ints(change)
    state
  end

  defp step(state, ["G", winner | _]) do
    assert state.phase == :game_over
    assert state.winner == String.to_integer(winner)
    state
  end

  defp apply!(state, action) do
    assert {:ok, next} = Engine.apply_action(state, action), "#{inspect(action)} rejected"
    next
  end
end
