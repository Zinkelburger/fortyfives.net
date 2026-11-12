defmodule Website45sV3.Analysis.Engine do
  @moduledoc """
  A pure, replayable 45s engine for the analysis board, for every variant in
  `Website45sV3.Analysis.Variant`.

  The live tables run on `GameController`, a process with timers and seats;
  the board instead needs to step back, branch and replay a game from its
  list of moves, so the rules live here as plain functions on a struct. They
  match the research engine (Frank-45s-Opus) bit for bit, which in turn
  matches the site's rules; `test/website_45s_v3/analysis/engine_test.exs`
  replays the research engine's hands to check.

  A game is a `Setup` (variant, deck seed or chosen deals, first dealer,
  starting scores) plus a list of actions:

    * `{:bid, seat, {value, suit}}` (a pass is `{0, nil}`)
    * `{:keep, seat, [card]}`
    * `{:play, seat, card}`
    * `:next_hand` once a hand is scored

  Cards are integer ids (see `Website45sV3.Analysis.Cards`), suits 0..3.
  """
  alias Website45sV3.Analysis.Cards
  alias Website45sV3.Analysis.Variant

  @winning_score 120
  @bid_values [15, 20, 25, 30]

  defmodule Setup do
    @moduledoc "Everything needed to replay a game besides its moves."
    @enforce_keys [:variant]
    defstruct [:variant, seed: 1, dealer: 0, scores: nil, decks: %{}]

    @type t :: %__MODULE__{
            variant: Website45sV3.Analysis.Variant.t(),
            seed: non_neg_integer(),
            dealer: non_neg_integer(),
            scores: [integer()] | nil,
            decks: %{pos_integer() => [0..51]}
          }
  end

  defstruct [
    :setup,
    :variant,
    :scores,
    :dealer,
    :phase,
    :deck,
    :hand_no,
    :pos,
    :dealt,
    :hands,
    :order,
    :bids,
    :high,
    :high_seat,
    :high_suit,
    :bid_turn,
    :bidder,
    :bid,
    :trump,
    :kept,
    :discards,
    :hist,
    :trick,
    :leader,
    :tricks,
    :last_trick,
    :bonus_seat,
    :result,
    :winner,
    history: []
  ]

  @type action ::
          {:bid, non_neg_integer(), {non_neg_integer(), 0..3 | nil}}
          | {:keep, non_neg_integer(), [0..51]}
          | {:play, non_neg_integer(), 0..51}
          | :next_hand

  ## Setup and dealing

  def new(%Setup{variant: variant} = setup) do
    scores = setup.scores || List.duplicate(0, Variant.sides(variant))

    deal(%__MODULE__{
      setup: setup,
      variant: variant,
      scores: scores,
      dealer: setup.dealer,
      hand_no: 1
    })
  end

  @doc "A game replayed from its setup through `actions`. Stops at the first illegal action."
  def replay(%Setup{} = setup, actions) do
    Enum.reduce_while(actions, {:ok, new(setup), 0}, fn action, {:ok, state, n} ->
      case apply_action(state, action) do
        {:ok, state} -> {:cont, {:ok, state, n + 1}}
        {:error, reason} -> {:halt, {:error, reason, state, n}}
      end
    end)
    |> case do
      {:ok, state, _n} -> {:ok, state}
      error -> error
    end
  end

  @doc "The deck for a hand: the one chosen in the setup, or a shuffle from the seed."
  def deck_for(%Setup{decks: decks, seed: seed}, hand_no) do
    Map.get_lazy(decks, hand_no, fn -> shuffle(seed, hand_no) end)
  end

  @doc "A deterministic shuffle: the same seed and hand always give the same deck."
  def shuffle(seed, hand_no) do
    rand = :rand.seed_s(:exsss, {seed + 1, hand_no + 7, 4545})

    {deck, _} =
      Enum.reduce(51..1//-1, {List.to_tuple(Enum.to_list(0..51)), rand}, fn i, {t, r} ->
        {j, r} = :rand.uniform_s(i + 1, r)
        j = j - 1
        {t |> put_elem(i, elem(t, j)) |> put_elem(j, elem(t, i)), r}
      end)

    Tuple.to_list(deck)
  end

  defp deal(%__MODULE__{variant: %Variant{n: n}} = state) do
    deck = deck_for(state.setup, state.hand_no)
    dealt = for p <- 0..(n - 1), into: %{}, do: {p, Enum.slice(deck, p * 5, 5)}

    %{
      state
      | phase: :bidding,
        deck: deck,
        pos: 5 * n,
        dealt: dealt,
        hands: dealt,
        order: nil,
        bids: %{},
        high: 0,
        high_seat: nil,
        high_suit: nil,
        bid_turn: 1,
        bidder: nil,
        bid: nil,
        trump: nil,
        kept: %{},
        discards: %{},
        hist: [],
        trick: [],
        leader: nil,
        tricks: List.duplicate(0, n),
        last_trick: nil,
        bonus_seat: nil,
        result: nil
    }
  end

  ## Whose move

  @doc "The seats that may act now (several while keeping, since everyone keeps at once)."
  def to_act(%__MODULE__{phase: :bidding} = s), do: [bidding_seat(s)]

  def to_act(%__MODULE__{phase: :discard, variant: %{n: n}} = s),
    do: Enum.reject(0..(n - 1), &Map.has_key?(s.kept, &1))

  def to_act(%__MODULE__{phase: :playing} = s), do: [playing_seat(s)]
  def to_act(_), do: []

  defp bidding_seat(%{dealer: d, bid_turn: k, variant: %{n: n}}), do: rem(d + k, n)
  defp playing_seat(%{leader: l, trick: t, variant: %{n: n}}), do: rem(l + length(t), n)

  @doc "Whether the dealer is bagged: everyone else passed."
  def bagged?(%__MODULE__{phase: :bidding, bid_turn: k, high: 0, variant: %{n: n}}), do: k == n
  def bagged?(_), do: false

  @doc """
  The choice in front of `seat`, or nil: `{:bid, bids}`, `{:keep, cards, min_keep}`
  or `{:play, cards}`.
  """
  def decision(%__MODULE__{} = s, seat) do
    if seat in to_act(s) do
      case s.phase do
        :bidding -> {:bid, legal_bids(s)}
        :discard -> {:keep, s.hands[seat], s.variant.min_keep}
        :playing -> {:play, legal_cards(s, seat)}
      end
    end
  end

  @doc "Legal bids for the seat to bid. A bagged dealer bids 15 in a suit of their choice."
  def legal_bids(%__MODULE__{} = s) do
    seat = bidding_seat(s)
    dealer? = seat == s.dealer

    if bagged?(s) do
      for suit <- 0..3, do: {15, suit}
    else
      [{0, nil}] ++
        for v <- @bid_values, v > s.high or (dealer? and v == s.high), suit <- 0..3, do: {v, suit}
    end
  end

  def legal_cards(%__MODULE__{} = s, seat) do
    led =
      case s.trick do
        [] -> nil
        [{_, c} | _] -> c
      end

    Cards.legal(s.hands[seat], led, s.trump)
  end

  ## Moves

  def apply_action(%__MODULE__{phase: :bidding} = s, {:bid, seat, {value, suit} = bid}) do
    cond do
      seat != bidding_seat(s) -> {:error, :not_your_turn}
      bid not in legal_bids(s) -> {:error, :illegal_bid}
      true -> {:ok, record_bid(s, seat, value, suit)}
    end
  end

  def apply_action(%__MODULE__{phase: :discard} = s, {:keep, seat, cards}) do
    hand = s.hands[seat]

    cond do
      Map.has_key?(s.kept, seat) or not is_list(hand) -> {:error, :not_your_turn}
      not (is_list(cards) and Enum.all?(cards, &(&1 in hand))) -> {:error, :illegal_keep}
      length(Enum.uniq(cards)) != length(cards) -> {:error, :illegal_keep}
      length(cards) < s.variant.min_keep or length(cards) > 5 -> {:error, :illegal_keep}
      true -> {:ok, record_keep(s, seat, cards)}
    end
  end

  def apply_action(%__MODULE__{phase: :playing} = s, {:play, seat, card}) do
    cond do
      seat != playing_seat(s) -> {:error, :not_your_turn}
      card not in legal_cards(s, seat) -> {:error, :illegal_card}
      true -> {:ok, record_play(s, seat, card)}
    end
  end

  def apply_action(%__MODULE__{phase: :hand_over} = s, :next_hand) do
    {:ok, deal(%{s | dealer: rem(s.dealer + 1, s.variant.n), hand_no: s.hand_no + 1})}
  end

  def apply_action(_state, _action), do: {:error, :out_of_turn}

  defp record_bid(s, seat, value, suit) do
    s = %{s | bids: Map.put(s.bids, seat, {value, suit})}
    s = if value > 0, do: %{s | high: value, high_seat: seat, high_suit: suit}, else: s

    if s.bid_turn == s.variant.n do
      start_discard(s)
    else
      %{s | bid_turn: s.bid_turn + 1}
    end
  end

  defp start_discard(s) do
    bidder = s.high_seat
    kitty = Enum.slice(s.deck, s.pos, 3)
    hand = s.dealt[bidder] ++ kitty

    %{
      s
      | phase: :discard,
        bidder: bidder,
        bid: s.high,
        trump: s.high_suit,
        pos: s.pos + 3,
        dealt: Map.put(s.dealt, bidder, hand),
        hands: Map.put(s.hands, bidder, hand)
    }
  end

  defp record_keep(s, seat, cards) do
    # Kept cards stay in the order they were dealt.
    kept = Enum.filter(s.hands[seat], &(&1 in cards))

    s = %{
      s
      | kept: Map.put(s.kept, seat, kept),
        discards: Map.put(s.discards, seat, s.hands[seat] -- kept)
    }

    if map_size(s.kept) == s.variant.n, do: draw(s), else: s
  end

  # Everyone draws back to five: from the dealer's left in cutthroat, in seat
  # order in the partnership game (as GameController deals).
  defp draw(%{variant: %{n: n} = variant} = s) do
    seats =
      if variant.draw_from_dealer_left,
        do: for(k <- 0..(n - 1), do: rem(s.dealer + 1 + k, n)),
        else: Enum.to_list(0..(n - 1))

    {order, pos} =
      Enum.reduce(seats, {%{}, s.pos}, fn p, {acc, pos} ->
        need = 5 - length(s.kept[p])
        {Map.put(acc, p, s.kept[p] ++ Enum.slice(s.deck, pos, need)), pos + need}
      end)

    bonus_seat =
      for(
        p <- 0..(n - 1),
        c <- order[p],
        Cards.trump?(c, s.trump),
        do: {Cards.trump_rank(c, s.trump), p}
      )
      |> Enum.max(fn -> {0, nil} end)
      |> elem(1)

    %{
      s
      | phase: :playing,
        pos: pos,
        order: order,
        hands: order,
        leader: s.bidder,
        bonus_seat: bonus_seat
    }
  end

  defp record_play(%{variant: %{n: n}} = s, seat, card) do
    s = %{
      s
      | hands: Map.update!(s.hands, seat, &List.delete(&1, card)),
        hist: s.hist ++ [{seat, card}],
        trick: s.trick ++ [{seat, card}],
        last_trick: nil
    }

    if length(s.trick) == n do
      cards = Enum.map(s.trick, &elem(&1, 1))
      winner = elem(Enum.at(s.trick, Cards.trick_winner(cards, s.trump)), 0)

      s = %{
        s
        | tricks: List.update_at(s.tricks, winner, &(&1 + 1)),
          last_trick: {s.trick, winner},
          trick: [],
          leader: winner
      }

      if length(s.hist) == 5 * n, do: score_hand(s), else: s
    else
      s
    end
  end

  defp score_hand(%{variant: variant} = s) do
    sides = Variant.sides(variant)
    points = List.duplicate(0, sides)

    points =
      s.tricks
      |> Enum.with_index()
      |> Enum.reduce(points, fn {t, p}, acc ->
        List.update_at(acc, Variant.side(variant, p), &(&1 + 5 * t))
      end)

    points =
      if s.bonus_seat,
        do: List.update_at(points, Variant.side(variant, s.bonus_seat), &(&1 + 5)),
        else: points

    bid_side = Variant.side(variant, s.bidder)
    made = Enum.at(points, bid_side) >= s.bid
    change = if made, do: points, else: List.replace_at(points, bid_side, -s.bid)
    scores = Enum.zip_with(s.scores, change, &(&1 + &2))

    result = %{
      hand: s.hand_no,
      dealer: s.dealer,
      bidder: s.bidder,
      bid: s.bid,
      trump: s.trump,
      made: made,
      points: points,
      change: change,
      tricks: s.tricks,
      bonus_seat: s.bonus_seat,
      scores: scores
    }

    winner = winner(variant, scores, bid_side)
    phase = if winner, do: :game_over, else: :hand_over

    %{
      s
      | scores: scores,
        result: result,
        history: s.history ++ [result],
        winner: winner,
        phase: phase
    }
  end

  # First to 120. When several get there in one hand the bidder goes out
  # first, then the highest score (the lowest seat on a tie).
  defp winner(_variant, scores, bid_side) do
    if Enum.at(scores, bid_side) >= @winning_score do
      bid_side
    else
      scores
      |> Enum.with_index()
      |> Enum.filter(fn {sc, _} -> sc >= @winning_score end)
      |> Enum.reduce(nil, fn
        {sc, i}, nil -> {sc, i}
        {sc, i}, {bs, _} when sc > bs -> {sc, i}
        _, best -> best
      end)
      |> then(fn best -> best && elem(best, 1) end)
    end
  end

  def winning_score, do: @winning_score

  ## What a seat may know, in the bots' view format

  @doc "The bid view for the seat to bid (see `Website45sV3.Analysis.CtPolicy`)."
  def bid_view(%__MODULE__{} = s, seat) do
    %{
      n: s.variant.n,
      seat: seat,
      dealer: s.dealer,
      hand: s.dealt[seat],
      bids: s.bids,
      high: s.high,
      high_seat: s.high_seat,
      bagged: bagged?(s),
      score: seat_scores(s)
    }
  end

  def keep_view(%__MODULE__{} = s, seat) do
    %{
      n: s.variant.n,
      seat: seat,
      dealer: s.dealer,
      bidder: s.bidder,
      bid: s.bid,
      trump: s.trump,
      min_keep: s.variant.min_keep,
      bids: s.bids,
      cards: s.dealt[seat],
      score: seat_scores(s)
    }
  end

  def play_view(%__MODULE__{} = s, seat) do
    n = s.variant.n
    hand = s.hands[seat]

    %{
      n: n,
      seat: seat,
      dealer: s.dealer,
      bidder: s.bidder,
      bid: s.bid,
      trump: s.trump,
      bids: s.bids,
      kept: for(p <- 0..(n - 1), do: length(s.kept[p])),
      hand: hand,
      order: Enum.map(s.order[seat], &if(&1 in hand, do: &1)),
      legal: legal_cards(s, seat),
      discards: s.discards[seat],
      hist: s.hist,
      trick_n: length(s.trick),
      tricks: List.to_tuple(s.tricks),
      score: seat_scores(s)
    }
  end

  @doc "Each seat's game score (a partner's is their team's)."
  def seat_scores(%__MODULE__{variant: variant, scores: scores}) do
    for(p <- 0..(variant.n - 1), do: Enum.at(scores, Variant.side(variant, p))) |> List.to_tuple()
  end
end
