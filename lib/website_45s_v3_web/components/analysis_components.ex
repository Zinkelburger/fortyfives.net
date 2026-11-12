defmodule Website45sV3Web.AnalysisComponents do
  @moduledoc """
  Markup for the analysis board. The table, hand and bidding controls reuse
  the live game's classes and the `CardSelection` hook, so the board looks
  and plays like a real table; the rail beside it (below it on a phone)
  holds the hints, the graph and the move list.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: Website45sV3Web.Endpoint,
    router: Website45sV3Web.Router,
    statics: Website45sV3Web.static_paths()

  alias Phoenix.LiveView.JS
  alias Website45sV3.Analysis.Advisor
  alias Website45sV3.Analysis.Cards
  alias Website45sV3.Analysis.Engine
  alias Website45sV3.Analysis.Variant
  alias Website45sV3.Game.Card

  @symbols %{0 => "♥", 1 => "♦", 2 => "♣", 3 => "♠"}
  @letters %{1 => "A", 11 => "J", 12 => "Q", 13 => "K"}
  @suit_buttons [
    {"hearts", "♥", "red"},
    {"diamonds", "♦", "red"},
    {"clubs", "♣", "black"},
    {"spades", "♠", "black"}
  ]

  ## Names and labels

  @doc "A seat's name at the board: You, Partner, Left, Right or Bot N."
  def seat_name(_variant, 0), do: "You"
  def seat_name(%Variant{teams: true}, 1), do: "Left"
  def seat_name(%Variant{teams: true}, 2), do: "Partner"
  def seat_name(%Variant{teams: true}, 3), do: "Right"
  def seat_name(%Variant{}, seat), do: "Bot #{seat}"

  def side_name(%Variant{teams: true}, 0), do: "You"
  def side_name(%Variant{teams: true}, 1), do: "Them"
  def side_name(variant, seat), do: seat_name(variant, seat)

  def card_text(id),
    do:
      Map.get(@letters, Cards.value(id), Integer.to_string(Cards.value(id))) <>
        @symbols[Cards.suit(id)]

  def red?(id), do: Cards.suit(id) in [0, 1]

  attr :id, :integer, required: true

  def ctext(assigns) do
    ~H"""
    <span class={["ctext", red?(@id) && "suit-red"]}>{card_text(@id)}</span>
    """
  end

  attr :suit, :integer, default: nil

  def suit(assigns) do
    ~H"""
    <span
      :if={@suit}
      class={["suit", @suit in [0, 1] && "suit-red"]}
      role="img"
      aria-label={Enum.at(~w(hearts diamonds clubs spades), @suit)}
    >{suit_symbol(@suit)}</span>
    """
  end

  def suit_symbol(s), do: @symbols[s]

  def bid_label({0, _}), do: "Pass"
  def bid_label({v, s}), do: "#{v} #{@symbols[s]}"

  def points(p) when is_float(p) do
    rounded = Float.round(p, 1)

    cond do
      rounded > 0 -> "+#{:erlang.float_to_binary(rounded, decimals: 1)}"
      rounded < 0 -> "−#{:erlang.float_to_binary(abs(rounded), decimals: 1)}"
      true -> "0.0"
    end
  end

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  def glyph(:inaccuracy), do: "?!"
  def glyph(:mistake), do: "?"
  def glyph(:blunder), do: "??"
  def glyph(_), do: nil

  def class_name(:best), do: "Best"
  def class_name(:good), do: "Good"
  def class_name(:inaccuracy), do: "Inaccuracy"
  def class_name(:mistake), do: "Mistake"
  def class_name(:blunder), do: "Blunder"

  defp image(id),
    do:
      "/images/cards/#{Card.card_to_filename({Cards.value(id), Cards.suit_atom(Cards.suit(id))})}.png"

  ## The board

  def board(assigns) do
    ~H"""
    <div id="analysis" class={["board", @hints && "board-hints"]} phx-hook="AnalysisKeys">
      <div
        id="game-container"
        class="game board-game"
        data-phase={phase_label(@state.phase)}
        data-seats={@state.variant.n}
        data-mode={@settings.mode}
      >
        <.board_header state={@state} settings={@settings} hints={@hints} />
        <.status {assigns} />
        <div class="game-play-area">
          <section class="phase-area" aria-label={phase_label(@state.phase)}>
            <%= case @state.phase do %>
              <% :bidding -> %>
                <.seat_table state={@state} />
                <.bidding_panel {assigns} />
              <% :discard -> %>
                <.seat_table state={@state} />
              <% :playing -> %>
                <.trick_table state={@state} />
              <% _ -> %>
                <.results state={@state} settings={@settings} live={@live} />
            <% end %>
          </section>
          <.hand_panel :if={@state.phase in [:bidding, :discard, :playing]} {assigns} />
        </div>
      </div>
      <.rail :if={@hints} {assigns} />
      <.play_mode_bar :if={not @hints} state={@state} />
    </div>
    <.dialogs {assigns} />
    """
  end

  defp phase_label(:bidding), do: "Bidding"
  defp phase_label(:discard), do: "Discard"
  defp phase_label(:playing), do: "Playing"
  defp phase_label(:hand_over), do: "Scoring"
  defp phase_label(:game_over), do: "Final Scoring"

  defp phase_title(:discard), do: "Discarding"
  defp phase_title(:hand_over), do: "Hand results"
  defp phase_title(:game_over), do: "Game over"
  defp phase_title(phase), do: phase_label(phase)

  attr :state, :map, required: true
  attr :settings, :map, required: true
  attr :hints, :boolean, required: true

  defp board_header(assigns) do
    assigns = assign(assigns, :score, header_score(assigns.state))

    ~H"""
    <header class="game-header">
      <a href="/" class="game-brand" aria-label="Forty Fives home">
        <img src={~p"/images/logo-mark.png"} alt="Forty Fives" width="44" height="40" />
      </a>
      <div class="game-score" aria-label={@score.label}>
        <span>{@score.left} <strong>{@score.left_score}</strong></span>
        <span class="score-divider" aria-hidden="true">/</span>
        <span>{@score.right} <strong>{@score.right_score}</strong></span>
      </div>
      <button
        id="open-menu"
        type="button"
        class="score-button"
        phx-click="dialog"
        phx-value-open="menu"
      >Menu</button>
      <button
        id="open-scores"
        type="button"
        class="score-button"
        phx-click="dialog"
        phx-value-open="scores"
      >Scores</button>
      <button
        id="open-rules"
        type="button"
        class="score-button"
        phx-click="dialog"
        phx-value-open="rules"
        aria-label="Quick rules"
      >?</button>
    </header>
    """
  end

  defp header_score(%{variant: %{teams: true} = v, scores: [us, them]}),
    do: %{
      left: side_name(v, 0),
      left_score: us,
      right: side_name(v, 1),
      right_score: them,
      label: "Your team #{us}, opponents #{them}"
    }

  defp header_score(%{variant: v, scores: [me | others]}) do
    {best, i} = others |> Enum.with_index(1) |> Enum.max_by(&elem(&1, 0))

    %{
      left: "You",
      left_score: me,
      right: seat_name(v, i),
      right_score: best,
      label: "You #{me}, best other #{best}"
    }
  end

  ## Status: phase, whose turn, the facts of the hand, and the hint line

  def status(assigns) do
    ~H"""
    <div id="game-status" class="game-status">
      <div class="phase-heading">
        <h1 class="phase-title" aria-live="polite">{phase_title(@state.phase)}</h1>
        <span :if={not @live} class="board-history-tag">Move {@cursor} of {length(@actions)}</span>
      </div>
      <div class="turn-line">
        <p class="turn-text" aria-live="polite">{turn_message(assigns)}</p>
      </div>
      <.facts state={@state} />
      <.hint_line :if={@hints} {assigns} />
    </div>
    """
  end

  defp turn_message(%{state: %{phase: :game_over} = state}), do: winner_message(state)

  defp turn_message(%{state: %{phase: :hand_over} = state}),
    do: result_line(state.result, state.variant)

  defp turn_message(%{state: %{phase: :discard} = state} = a) do
    cond do
      a.hand_seat not in Engine.to_act(state) -> "Cards kept · Waiting for others"
      a.hand_seat == 0 -> "Tap the cards you want to keep"
      true -> "#{seat_name(state.variant, a.hand_seat)} · Tap the cards you want to keep"
    end
  end

  defp turn_message(%{state: state} = a) do
    if trick_just_won?(a),
      do: "#{seat_name(state.variant, elem(state.last_trick, 1))} won the trick",
      else: whose_turn(state, a.hand_seat)
  end

  # A finished trick stays on the table until the next card; say who took it,
  # unless it is your lead now.
  defp trick_just_won?(%{state: state} = a) do
    match?({_, _}, state.last_trick) and state.trick == [] and
      not (a.live and a.hand_seat in Engine.to_act(state))
  end

  defp whose_turn(state, hand_seat) do
    v = state.variant

    case Engine.to_act(state) do
      [^hand_seat] when state.phase == :bidding ->
        if Engine.bagged?(state),
          do: "#{you(v, hand_seat)}bid is 15 · Choose trump",
          else: "#{you(v, hand_seat)}turn · Choose a bid and trump"

      [^hand_seat] ->
        "#{you(v, hand_seat)}turn · Choose a card"

      [seat] ->
        "#{seat_name(v, seat)}'s turn"

      _ ->
        ""
    end
  end

  defp you(_v, 0), do: "Your "
  defp you(v, seat), do: "#{seat_name(v, seat)}'s "

  defp winner_message(%{winner: w, variant: v}) do
    cond do
      v.teams and w == 0 -> "Your team wins!"
      v.teams -> "Opponents win"
      w == 0 -> "You win!"
      true -> "#{seat_name(v, w)} wins"
    end
  end

  defp result_line(nil, _v), do: ""

  defp result_line(r, v) do
    bidder = seat_name(v, r.bidder)
    if r.made, do: "#{bidder} made #{r.bid}", else: "#{bidder} went set · −#{r.bid}"
  end

  attr :state, :map, required: true

  defp facts(assigns) do
    s = assigns.state
    assigns = assign(assigns, v: s.variant, tricks: s.tricks)

    ~H"""
    <%= case @state.phase do %>
      <% :bidding -> %>
        <p class="game-facts" aria-live="polite">
          <span :if={@state.high_seat} class="facts-main">
            High bid:<span class="facts-name">{seat_name(@v, @state.high_seat)}</span>{@state.high}
            <.suit suit={@state.high_suit} />
          </span>
          <span :if={!@state.high_seat}>No bids yet</span>
          <span>Dealer: {seat_name(@v, @state.dealer)}</span>
        </p>
      <% phase when phase in [:discard, :playing] -> %>
        <p class="game-facts" aria-live="polite">
          <span class="facts-main">
            <span class="trump">Trump <.suit suit={@state.trump} /></span>
            ·<span class="facts-name">{seat_name(@v, @state.bidder)}</span>bid {@state.bid}
          </span>
          <span :if={phase == :playing}>{tricks_line(@state)}</span>
        </p>
      <% _ -> %>
        <p class="game-facts">
          <span>Hand {@state.hand_no}</span>
          <span :if={@state.result} class="facts-main">
            <span class="facts-name">{seat_name(@v, @state.result.bidder)}</span>bid {@state.result.bid}
            <.suit suit={@state.result.trump} />
          </span>
        </p>
    <% end %>
    """
  end

  defp tricks_line(%{variant: %{teams: true}, tricks: [a, b, c, d]}),
    do: "Tricks: You #{a + c} · Them #{b + d}"

  defp tricks_line(%{variant: v, tricks: tricks}) do
    "Tricks: " <>
      Enum.map_join(Enum.with_index(tricks), " · ", fn {t, p} -> "#{short_name(v, p)} #{t}" end)
  end

  defp short_name(_v, 0), do: "You"
  defp short_name(%{teams: true} = v, p), do: seat_name(v, p)
  defp short_name(_v, p), do: "B#{p}"

  # One line under the facts, so the hint is in the first screen on a phone.
  defp hint_line(assigns) do
    assigns = assign(assigns, :last, last_judgment(assigns))

    ~H"""
    <div class="hint-line" aria-live="polite">
      <%= cond do %>
        <% @show_options and @options == :loading -> %>
          <span class="hint-muted">Thinking…</span>
        <% @show_options and is_list(@options) and @options != [] -> %>
          <% [best | _] = @options %>
          <span>Best <strong><.act action={best.action} trump={@state.trump} /></strong>
          <span class="pts pts-best">{points(best.points)}</span></span>
          <span :if={@last} class={["hint-last", "judge-#{@last.class}"]}>
            Your last: {class_name(@last.class)} {loss_text(@last)}
          </span>
        <% @last -> %>
          <span class={["hint-last", "judge-#{@last.class}"]}>
            Your
            <.act action={@last.chosen.action} trump={@state.trump} />: {class_name(@last.class)} {loss_text(
              @last
            )}
            <span :if={@last.class not in [:best, :good]}>· best
            <.act action={@last.best.action} trump={@state.trump} /></span>
          </span>
        <% @show_options and @options == [] -> %>
          <span class="hint-muted">No hints for {Variant.label(@state.variant)} yet</span>
        <% true -> %>
          <span class="hint-muted"></span>
      <% end %>
    </div>
    """
  end

  defp loss_text(%{class: :best}), do: ""

  defp loss_text(%{loss: loss}),
    do: "(−#{:erlang.float_to_binary(Float.round(loss, 1), decimals: 1)})"

  # Your most recent judged decision before this position.
  defp last_judgment(%{judgments: judgments, cursor: cursor}) do
    judgments
    |> Enum.filter(fn {i, _} -> i < cursor end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> nil
      {_, j} -> j
    end
  end

  def action_label({:bid, _, bid}, _state), do: bid_label(bid)
  def action_label({:play, _, card}, _state), do: card_text(card)

  def action_label({:keep, _, kept}, state),
    do:
      if(kept == [],
        do: "nothing",
        else:
          kept |> Cards.sort_for_display(state && state.trump) |> Enum.map_join(" ", &card_text/1)
      )

  def action_label(:next_hand, _), do: "Next hand"

  attr :action, :any, required: true
  attr :trump, :integer, default: nil

  @doc "An action as it reads at the table, with red suits in red."
  def act(%{action: {:bid, _, {0, _}}} = assigns), do: ~H"Pass"

  def act(%{action: {:bid, _, {v, s}}} = assigns) do
    assigns = assign(assigns, v: v, s: s)
    ~H"{@v} <.suit suit={@s} />"
  end

  def act(%{action: {:play, _, card}} = assigns) do
    assigns = assign(assigns, :card, card)
    ~H"<.ctext id={@card} />"
  end

  def act(%{action: {:keep, _, []}} = assigns), do: ~H"nothing"

  def act(%{action: {:keep, _, kept}} = assigns) do
    assigns = assign(assigns, :cards, Cards.sort_for_display(kept, assigns.trump))
    ~H"<.ctext :for={c <- @cards} id={c} />"
  end

  def act(assigns), do: ~H""

  ## The table

  attr :state, :map, required: true

  defp seat_table(assigns) do
    s = assigns.state

    seats =
      for p <- 0..(s.variant.n - 1),
          do: %{
            seat: p,
            name: seat_name(s.variant, p),
            status: seat_status(s, p),
            on_turn: p in Engine.to_act(s)
          }

    assigns = assign(assigns, seats: seats, n: s.variant.n)

    ~H"""
    <div class={["seat-table", "board-seats", "seats-#{@n}"]} aria-label="Players">
      <div
        :for={seat <- @seats}
        id={"seat-chip-#{seat.seat}"}
        class={["seat-chip", "pos-#{seat.seat}", seat.on_turn && "seat-on-turn"]}
      >
        <p class="seat-name">
          <span class="seat-name-text">{seat.name}</span>
          <span :if={@state.dealer == seat.seat} class="seat-tag">· dealer</span>
        </p>
        <p class="seat-status">
          <%= case seat.status do %>
            <% {:bid, bid, suit} -> %>
              {bid} <.suit suit={suit} />
            <% :pass -> %>
              Pass
            <% :ready -> %>
              Ready
            <% :waiting -> %>
              <span class="seat-waiting" aria-label="Not yet">–</span>
          <% end %>
        </p>
      </div>
    </div>
    """
  end

  defp seat_status(%{phase: :bidding, bids: bids}, p) do
    case Map.get(bids, p) do
      {0, _} -> :pass
      {v, s} -> {:bid, v, s}
      nil -> :waiting
    end
  end

  defp seat_status(%{phase: :discard, kept: kept}, p),
    do: if(Map.has_key?(kept, p), do: :ready, else: :waiting)

  defp seat_status(_, _), do: :waiting

  attr :state, :map, required: true

  defp trick_table(assigns) do
    s = assigns.state

    {cards, winner} =
      case {s.trick, s.last_trick} do
        {[], {cards, winner}} -> {cards, winner}
        {trick, _} -> {trick, nil}
      end

    on_turn = Engine.to_act(s)

    seats =
      for p <- 0..(s.variant.n - 1) do
        %{
          seat: p,
          name: seat_name(s.variant, p),
          card: Enum.find_value(cards, fn {q, c} -> if q == p, do: c end),
          on_turn: p in on_turn and winner == nil
        }
      end

    assigns = assign(assigns, seats: seats, winner: winner, n: s.variant.n)

    ~H"""
    <div class="played-cards">
      <div
        id="table"
        class={["table", "board-table", "seats-#{@n}", @winner && "trick-done"]}
        aria-label="Current trick"
      >
        <div
          :for={seat <- @seats}
          id={"seat-#{seat.seat}"}
          class={[
            "player-slot",
            "pos-#{seat.seat}",
            seat.on_turn && "seat-on-turn",
            seat.seat == @winner && "trick-winner"
          ]}
        >
          <p class="player-name">
            <span class="seat-name-text">{seat.name}</span>
            <span :if={seat.seat == @state.bidder} class="seat-tag">· bid</span>
          </p>
          <%= if seat.card do %>
            <img
              class="card"
              src={image(seat.card)}
              alt={"#{seat.name} played the #{Cards.name(seat.card)}"}
            />
          <% else %>
            <div class="empty-card" aria-label={"#{seat.name} has not played"}></div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  ## Bidding

  defp bidding_panel(assigns) do
    s = assigns.state
    acting = hd(Engine.to_act(s))
    can = acting == assigns.hand_seat and (acting == 0 or assigns.control_all)
    legal = Engine.legal_bids(s)
    values = for {v, _} <- legal, v > 0, uniq: true, do: v
    bagged = Engine.bagged?(s)
    selected_bid = if bagged and can, do: "15", else: assigns.selected_bid

    assigns =
      assign(assigns,
        can: can,
        values: values,
        bagged: bagged,
        selected_bid: selected_bid,
        buttons: @suit_buttons
      )

    ~H"""
    <div class="bidding-panel">
      <div class="bid-options">
        <div class="bid-numbers" role="group" aria-label="Bid amount">
          <button
            :for={bid <- [15, 20, 25, 30]}
            type="button"
            class={["blue-button", @selected_bid == Integer.to_string(bid) && "active"]}
            phx-click="set_bid_number"
            phx-value-bid-number={bid}
            aria-pressed={to_string(@selected_bid == Integer.to_string(bid))}
            disabled={not @can or bid not in @values}
          >{bid}</button>
        </div>
        <div class="bid-suits" role="group" aria-label="Trump suit">
          <button
            :for={{suit, symbol, color} <- @buttons}
            type="button"
            class={["suit-button", color == "red" && "red-suit", @selected_suit == suit && "active"]}
            phx-click="set_bid_suit"
            phx-value-bid-suit={suit}
            aria-label={String.capitalize(suit)}
            aria-pressed={to_string(@selected_suit == suit)}
            disabled={not @can}
          >{symbol}</button>
        </div>
      </div>
    </div>
    """
  end

  ## The hand

  def hand_panel(assigns) do
    s = assigns.state
    seat = assigns.hand_seat
    acting = seat in Engine.to_act(s)
    decision = acting && Engine.decision(s, seat)
    locked = not acting or s.phase == :bidding
    cards = hand_cards(s, seat, decision, locked)
    badges = badges(assigns, s.phase)
    confirmed = s.phase == :discard and Map.has_key?(s.kept, seat)

    assigns =
      assign(assigns,
        cards: cards,
        locked: locked,
        badges: badges,
        confirmed: confirmed,
        can_bid: acting and s.phase == :bidding,
        version: "#{assigns.cursor}|#{length(assigns.actions)}|#{seat}|#{s.phase}"
      )

    ~H"""
    <section
      id="player-hand"
      class={["hand-panel", @hints && "hand-panel-hints"]}
      phx-hook="CardSelection"
      aria-label={
        if @hand_seat == 0, do: "Your hand", else: "#{seat_name(@state.variant, @hand_seat)}'s hand"
      }
      data-phase={phase_label(@state.phase)}
      data-locked={to_string(@locked)}
      data-auto-playing="false"
      data-confirmed={to_string(@confirmed)}
      data-selection-version={@version}
    >
      <p :if={@hand_seat != 0} class="hand-owner">{seat_name(@state.variant, @hand_seat)}'s hand</p>
      <div class={["player-hand", length(@cards) > 5 && "player-hand-eight"]}>
        <button
          :for={card <- @cards}
          type="button"
          id={"card-button-#{card.value}"}
          class={[
            "card-button",
            @badges[card.id] && "has-badge",
            @badges[card.id] && @badges[card.id].best && "card-best"
          ]}
          data-card={card.value}
          aria-label={card.name <> badge_label(@badges[card.id])}
          aria-pressed="false"
          aria-disabled={to_string(not card.playable)}
          disabled={not card.playable}
        >
          <img
            id={"hand-card-#{card.value}"}
            src={image(card.id)}
            alt={card.name}
            class={["card", card.illegal && "grayed-out"]}
            data-card-value={card.value}
            draggable="false"
          />
          <span class="card-check" aria-hidden="true">✓</span>
          <span
            :if={@badges[card.id]}
            class={["card-value", @badges[card.id].best && "card-value-best"]}
            aria-hidden="true"
          >{@badges[card.id].text}</span>
        </button>
      </div>
      <.hand_action {assigns} />
    </section>
    """
  end

  defp badge_label(nil), do: ""
  defp badge_label(%{text: text, best: best}), do: ", #{text}#{if best, do: ", best", else: ""}"

  defp hand_cards(s, seat, decision, locked) do
    legal =
      case decision do
        {:play, cards} -> cards
        _ -> nil
      end

    s.hands[seat]
    |> Cards.sort_for_display(s.trump)
    |> Enum.map(fn id ->
      ok = legal == nil or id in legal

      %{
        id: id,
        value: Cards.encode(id),
        name: Cards.name(id),
        playable: not locked and ok,
        illegal: legal != nil and not ok
      }
    end)
  end

  # Values on the cards: each legal card's points while playing, and the
  # best keep's cards while discarding.
  defp badges(
         %{show_options: true, options: [_ | _] = options, focus: focus, hand_seat: focus},
         :playing
       ) do
    best = hd(options).points

    Map.new(options, fn %{action: {:play, _, c}, points: p} ->
      {c, %{text: points(p), best: p == best}}
    end)
  end

  defp badges(
         %{
           show_options: true,
           options: [%{action: {:keep, _, kept}} | _],
           focus: focus,
           hand_seat: focus
         },
         :discard
       ) do
    Map.new(kept, &{&1, %{text: "Keep", best: true}})
  end

  defp badges(_assigns, _phase), do: %{}

  defp hand_action(assigns) do
    ~H"""
    <%= if @state.phase == :bidding do %>
      <p class="selection-summary" aria-live="polite">
        {@bid_error || bid_summary(@selected_bid, @selected_suit)}
      </p>
      <div class="confirm-bid">
        <button
          type="button"
          id="pass-bid-button"
          class={["blue-button pass-button", @selected_suit == "pass" && "active"]}
          phx-click="set_bid_pass"
          aria-pressed={to_string(@selected_suit == "pass")}
          disabled={not @can_bid or Engine.bagged?(@state)}
        >Pass</button>
        <button
          type="button"
          id="confirm-bid-button"
          class="blue-button"
          phx-click="confirm_bid"
          disabled={
            not @can_bid or not bid_ready?(@selected_bid, @selected_suit, Engine.bagged?(@state))
          }
        >{if @selected_suit == "pass", do: "Confirm Pass", else: "Confirm Bid"}</button>
      </div>
    <% else %>
      <p id="selection-summary" class="selection-summary" aria-live="polite"></p>
      <button
        :if={@state.phase == :discard}
        type="button"
        id="confirm-discard-button"
        class="blue-button hand-action"
        data-hand-action="confirm_discard"
        disabled
      >Choose cards to keep</button>
      <button
        :if={@state.phase == :playing}
        type="button"
        id="play-card-button"
        class="blue-button hand-action"
        data-hand-action="play-card"
        disabled
      >Play Card</button>
    <% end %>
    """
  end

  defp bid_ready?(_bid, suit, true), do: suit not in [nil, "pass"]
  defp bid_ready?(nil, _suit, _), do: false
  defp bid_ready?(_bid, nil, _), do: false
  defp bid_ready?("0", suit, _), do: suit == "pass"
  defp bid_ready?(_bid, suit, _), do: suit != "pass"

  defp bid_summary("0", "pass"), do: "Pass"
  defp bid_summary(nil, nil), do: ""

  defp bid_summary(nil, suit),
    do: "#{@symbols[Cards.suit_index(String.to_existing_atom(suit))]} · choose a bid"

  defp bid_summary(bid, nil), do: "#{bid} · choose trump"

  defp bid_summary(bid, suit),
    do: "Bid #{bid} #{@symbols[Cards.suit_index(String.to_existing_atom(suit))]}"

  ## Hand results

  attr :state, :map, required: true
  attr :settings, :map, required: true
  attr :live, :boolean, required: true

  defp results(assigns) do
    s = assigns.state
    v = s.variant
    r = s.result

    sides =
      for i <- 0..(Variant.sides(v) - 1),
          do: %{name: side_name(v, i), score: Enum.at(s.scores, i), change: Enum.at(r.change, i)}

    assigns = assign(assigns, v: v, r: r, sides: sides)

    ~H"""
    <div class="scoring-panel">
      <div class={["score-totals", "score-totals-#{length(@sides)}"]}>
        <div :for={side <- @sides}>
          <span>{side.name}</span>
          <strong>{minus(side.score)}</strong>
          <small class={[side.change < 0 && "negative"]}>{signed(side.change)}</small>
        </div>
      </div>
      <p class="game-hint">
        {seat_name(@v, @r.bidder)} bid {@r.bid} <.suit suit={@r.trump} />
        · {if @r.made,
          do: "made it with #{Enum.at(@r.points, Variant.side(@v, @r.bidder))}",
          else: "set with #{Enum.at(@r.points, Variant.side(@v, @r.bidder))}"}
        <span :if={@r.bonus_seat}> · {seat_name(@v, @r.bonus_seat)} held the best trump</span>
      </p>
      <div :if={@live} class="final-actions">
        <button
          :if={@state.phase == :hand_over}
          id="next-hand-button"
          type="button"
          class="blue-button"
          phx-click="next_hand"
        >Next hand</button>
        <button
          :if={@state.phase == :game_over}
          id="rematch-button"
          type="button"
          class="blue-button"
          phx-click="rematch"
        >Play again</button>
        <button
          :if={@state.phase == :game_over}
          type="button"
          class="blue-button pass-button"
          phx-click="new_game"
        >New game</button>
      </div>
    </div>
    """
  end

  defp signed(0), do: "±0"
  defp signed(n) when n > 0, do: "+#{n}"
  defp signed(n), do: "−#{abs(n)}"
  defp minus(n) when n < 0, do: "−#{abs(n)}"
  defp minus(n), do: "#{n}"

  ## Play mode: no hints until the game is over

  defp play_mode_bar(assigns) do
    ~H"""
    <p class="board-play-note">Play mode · hints after the game</p>
    """
  end

  ## The rail

  def rail(assigns) do
    mine =
      assigns.judgments
      |> Enum.filter(fn {i, _} -> match?({_, 0, _}, Enum.at(assigns.actions, i)) end)
      |> Enum.sort()

    assigns = assign(assigns, mine: mine)

    ~H"""
    <aside class="board-rail" aria-label="Analysis">
      <.nav_bar {assigns} />
      <.summary :if={@mine != []} mine={@mine} />
      <.options_card {assigns} />
      <.graph mine={@mine} actions={@actions} cursor={@cursor} />
      <.move_list {assigns} />
      <.hands_card :if={@reveal} state={@state} />
      <.board_settings {assigns} />
    </aside>
    """
  end

  attr :d, :string, required: true

  defp nav_icon(assigns) do
    ~H"""
    <svg class="nav-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d={@d} />
    </svg>
    """
  end

  defp nav_bar(assigns) do
    ~H"""
    <div class="rail-nav" role="group" aria-label="Move through the game">
      <button
        type="button"
        class="score-button"
        phx-click="nav"
        phx-value-to="start"
        aria-label="First move"
        disabled={@cursor == 0}
      ><.nav_icon d="M6 5v14M18 6l-8 6 8 6z" /></button>
      <button
        type="button"
        class="score-button"
        phx-click="nav"
        phx-value-to="back"
        aria-label="Previous move"
        disabled={@cursor == 0}
      ><.nav_icon d="M16 6l-8 6 8 6z" /></button>
      <button
        type="button"
        class="score-button"
        phx-click="nav"
        phx-value-to="forward"
        aria-label="Next move"
        disabled={@live}
      ><.nav_icon d="M8 6l8 6-8 6z" /></button>
      <button
        type="button"
        class="score-button"
        phx-click="nav"
        phx-value-to="end"
        aria-label="Last move"
        disabled={@live}
      ><.nav_icon d="M18 5v14M6 6l8 6-8 6z" /></button>
      <button
        :if={@settings.mode == :analysis and @live}
        type="button"
        class="score-button rail-wide"
        phx-click="takeback"
        disabled={@actions == []}
      >Take back</button>
      <button :if={@mainline} type="button" class="score-button rail-wide" phx-click="back_to_game">Back to game</button>
    </div>
    """
  end

  attr :mine, :list, required: true

  defp summary(assigns) do
    judged = Enum.map(assigns.mine, &elem(&1, 1))
    counts = Enum.frequencies_by(judged, & &1.class)

    assigns =
      assign(assigns, accuracy: Advisor.accuracy(judged), counts: counts, n: length(judged))

    ~H"""
    <section class="rail-card rail-summary" aria-label="Your play">
      <div class="summary-accuracy">
        <strong>{@accuracy}%</strong><span>accuracy · {@n} decisions</span>
      </div>
      <ul class="summary-counts">
        <li class="judge-inaccuracy">
          <strong>{Map.get(@counts, :inaccuracy, 0)}</strong> {plural(
            Map.get(@counts, :inaccuracy, 0),
            "inaccuracy",
            "inaccuracies"
          )}
        </li>
        <li class="judge-mistake">
          <strong>{Map.get(@counts, :mistake, 0)}</strong> {plural(
            Map.get(@counts, :mistake, 0),
            "mistake",
            "mistakes"
          )}
        </li>
        <li class="judge-blunder">
          <strong>{Map.get(@counts, :blunder, 0)}</strong> {plural(
            Map.get(@counts, :blunder, 0),
            "blunder",
            "blunders"
          )}
        </li>
      </ul>
    </section>
    """
  end

  defp options_card(assigns) do
    played = Enum.at(assigns.actions, assigns.cursor)
    played = if played == :next_hand, do: nil, else: played
    assigns = assign(assigns, played: played)

    ~H"""
    <section class="rail-card" aria-label="Choices">
      <h2 class="rail-title">
        <%= cond do %>
          <% @focus == nil -> %>
            Choices
          <% @focus == 0 -> %>
            Your choices
          <% true -> %>
            {seat_name(@state.variant, @focus)}'s choices
        <% end %>
        <span class="rail-unit">points this hand</span>
      </h2>
      <%= cond do %>
        <% not @show_options -> %>
          <p class="rail-empty">{options_empty_text(assigns)}</p>
        <% @options == :loading -> %>
          <p class="rail-empty">Thinking…</p>
        <% @options == [] -> %>
          <p class="rail-empty">No hints for {Variant.label(@state.variant)} yet.</p>
        <% true -> %>
          <% best = hd(@options).points %>
          <ol class="option-list">
            <li :for={{opt, i} <- Enum.with_index(Enum.take(@options, 12))}>
              <button
                type="button"
                class={[
                  "option-row",
                  i == 0 && "option-best",
                  @played && same_action?(opt.action, @played) && "option-played"
                ]}
                phx-click="play_option"
                phx-value-i={i}
              >
                <span class="option-label"><.act action={opt.action} trump={@state.trump} /></span>
                <span :if={@played && same_action?(opt.action, @played)} class="option-tag">played</span>
                <span class="pts">{points(opt.points)}</span>
                <span class="option-delta">{if i == 0, do: "best", else: points(opt.points - best)}</span>
              </button>
            </li>
          </ol>
          <p :if={length(@options) > 12} class="rail-more">and {length(@options) - 12} more</p>
      <% end %>
    </section>
    """
  end

  defp options_empty_text(a) do
    cond do
      a.state.phase in [:hand_over, :game_over] ->
        "Hand over."

      a.focus == nil ->
        "Waiting for the bots."

      true ->
        "#{seat_name(a.state.variant, a.focus)} is thinking. Turn on Show all hands to see bots' choices."
    end
  end

  defp same_action?({:keep, s, a}, {:keep, s, b}), do: Enum.sort(a) == Enum.sort(b)
  defp same_action?(a, b), do: a == b

  ## The graph: your expected points after each decision, mistakes marked

  attr :mine, :list, required: true
  attr :actions, :list, required: true
  attr :cursor, :integer, required: true

  defp graph(assigns) do
    hands = hand_numbers(assigns.actions)
    points = assigns.mine
    n = length(points)
    w = 320
    h = 120
    mid = h / 2
    scale = (h / 2 - 8) / 30
    x = fn k -> if n <= 1, do: w / 2, else: 8 + k * (w - 16) / (n - 1) end
    y = fn p -> mid - max(min(p, 30), -30) * scale end

    pts =
      points
      |> Enum.with_index()
      |> Enum.map(fn {{i, j}, k} ->
        %{i: i, x: x.(k), y: y.(j.chosen.points), j: j, hand: Enum.at(hands, i)}
      end)

    seps =
      pts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, b] -> a.hand != b.hand end)
      |> Enum.map(fn [a, b] -> %{x: (a.x + b.x) / 2, hand: b.hand} end)

    line = Enum.map_join(pts, " ", &"#{fmt(&1.x)},#{fmt(&1.y)}")

    area =
      if pts == [],
        do: "",
        else: "#{fmt(hd(pts).x)},#{mid} #{line} #{fmt(List.last(pts).x)},#{mid}"

    current = pts |> Enum.filter(&(&1.i < assigns.cursor)) |> List.last()

    assigns =
      assign(assigns,
        w: w,
        h: h,
        mid: mid,
        pts: pts,
        seps: seps,
        line: line,
        area: area,
        current: current
      )

    ~H"""
    <section :if={@pts != []} class="rail-card" aria-label="Your decisions, graphed">
      <h2 class="rail-title">
        Game <span class="rail-unit">expected points after each of your decisions</span>
      </h2>
      <svg
        class="eval-graph"
        viewBox={"0 0 #{@w} #{@h}"}
        role="img"
        aria-label="Expected points after each of your decisions"
      >
        <line x1="0" x2={@w} y1={@mid} y2={@mid} class="graph-zero" />
        <text x="2" y="9" class="graph-label">+30</text>
        <text x="2" y={@h - 2} class="graph-label">−30</text>
        <g :for={sep <- @seps}>
          <line x1={fmt(sep.x)} x2={fmt(sep.x)} y1="0" y2={@h} class="graph-sep" />
          <text x={fmt(sep.x + 3)} y="11" class="graph-label">H{sep.hand}</text>
        </g>
        <polygon points={@area} class="graph-area" />
        <polyline points={@line} class="graph-line" />
        <line
          :if={@current}
          x1={fmt(@current.x)}
          x2={fmt(@current.x)}
          y1="0"
          y2={@h}
          class="graph-cursor"
        />
        <g :for={p <- @pts}>
          <circle
            :if={p.j.class in [:inaccuracy, :mistake, :blunder]}
            cx={fmt(p.x)}
            cy={fmt(p.y)}
            r="4"
            class={"graph-dot judge-#{p.j.class}"}
          />
          <circle
            cx={fmt(p.x)}
            cy={fmt(p.y)}
            r="9"
            class="graph-hit"
            phx-click="nav"
            phx-value-to={p.i}
          >
            <title>Hand {p.hand}: {class_name(p.j.class)} {points(p.j.chosen.points)}</title>
          </circle>
        </g>
      </svg>
    </section>
    """
  end

  defp fmt(x), do: :erlang.float_to_binary(x / 1, decimals: 1)

  # The hand each action belongs to.
  defp hand_numbers(actions) do
    {nums, _} =
      Enum.map_reduce(actions, 1, fn a, h -> if a == :next_hand, do: {h, h + 1}, else: {h, h} end)

    nums
  end

  ## The move list, grouped by hand: bids, keeps, then the tricks

  defp move_list(assigns) do
    hands = group_moves(assigns.setup, assigns.actions)
    assigns = assign(assigns, hands: hands, v: assigns.setup.variant)

    ~H"""
    <section class="rail-card" aria-label="Moves">
      <h2 class="rail-title">Moves</h2>
      <p :if={@hands == []} class="rail-empty">No moves yet.</p>
      <div class="move-list" id="move-list" phx-hook="ScrollCurrent">
        <div :for={hand <- @hands} class="move-hand">
          <h3 class="move-hand-title">
            Hand {hand.no} <span>· {seat_name(@v, hand.dealer)} dealt</span>
          </h3>
          <div :for={{label, moves} <- hand.rows} class="move-row">
            <span class="move-row-label">{label}</span>
            <span class="move-chips">
              <button
                :for={m <- moves}
                type="button"
                class={[
                  "move-chip",
                  m.i == @cursor - 1 && "move-current",
                  m.winner && "move-winner",
                  @judgments[m.i] && "judge-#{@judgments[m.i].class}"
                ]}
                phx-click="nav"
                phx-value-to={m.i}
                title={"#{seat_name(@v, m.seat)}: #{m.label}"}
              >
                <span class="move-who">{short_name(@v, m.seat)}</span>
                <span class="move-what"><%= if m.hidden do %>
                  {m.label}
                <% else %>
                  <.act action={m.action} trump={m.trump} />
                <% end %></span>
                <span :if={@judgments[m.i] && glyph(@judgments[m.i].class)} class="move-glyph">{glyph(
                  @judgments[m.i].class
                )}</span>
              </button>
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp group_moves(setup, actions) do
    state = Engine.new(setup)

    {hands, _state, current} =
      actions
      |> Enum.with_index()
      |> Enum.reduce({[], state, new_hand(state)}, fn {action, i}, {hands, state, cur} ->
        {:ok, next} = Engine.apply_action(state, action)

        if action == :next_hand,
          do: {[cur | hands], next, new_hand(next)},
          else: {hands, next, add_action(cur, action, i, state, next)}
      end)

    Enum.reverse([current | hands]) |> Enum.reject(&(&1.rows == []))
  end

  defp add_action(cur, {:bid, seat, bid}, i, _state, _next),
    do: add_move(cur, "Bids", move(i, seat, {:bid, seat, bid}, bid_label(bid), nil))

  defp add_action(cur, {:keep, seat, kept} = action, i, state, _next) do
    m = move(i, seat, action, action_label(action, state), state.trump)
    m = if seat == 0, do: m, else: %{m | hidden: true, label: "#{length(kept)}"}
    add_move(cur, "Keep", m)
  end

  defp add_action(cur, {:play, seat, card}, i, state, next) do
    row = "T#{div(length(state.hist), state.variant.n) + 1}"
    cur = add_move(cur, row, move(i, seat, {:play, seat, card}, card_text(card), state.trump))

    case next do
      %{trick: [], last_trick: {_, winner}} -> mark_winner(cur, row, winner)
      _ -> cur
    end
  end

  defp move(i, seat, action, label, trump),
    do: %{
      i: i,
      seat: seat,
      action: action,
      label: label,
      trump: trump,
      winner: false,
      hidden: false
    }

  defp new_hand(state), do: %{no: state.hand_no, dealer: state.dealer, rows: []}

  defp add_move(%{rows: rows} = hand, label, move) do
    rows =
      case List.last(rows) do
        {^label, moves} -> List.replace_at(rows, -1, {label, moves ++ [move]})
        _ -> rows ++ [{label, [move]}]
      end

    %{hand | rows: rows}
  end

  defp mark_winner(hand, label, winner) do
    rows =
      Enum.map(hand.rows, fn
        {^label, moves} -> {label, Enum.map(moves, &%{&1 | winner: &1.seat == winner})}
        row -> row
      end)

    %{hand | rows: rows}
  end

  attr :state, :map, required: true

  defp hands_card(assigns) do
    s = assigns.state

    seats =
      for p <- 0..(s.variant.n - 1), do: {p, Cards.sort_for_display(s.hands[p] || [], s.trump)}

    kitty = if s.phase == :bidding, do: Enum.slice(s.deck, 5 * s.variant.n, 3), else: []
    assigns = assign(assigns, seats: seats, kitty: kitty)

    ~H"""
    <section class="rail-card" aria-label="All hands">
      <h2 class="rail-title">All hands</h2>
      <dl class="hands-list">
        <div :for={{p, cards} <- @seats}>
          <dt>{seat_name(@state.variant, p)}</dt>
          <dd><.ctext :for={c <- cards} id={c} /></dd>
        </div>
        <div :if={@kitty != []}>
          <dt>Kitty</dt>
          <dd><.ctext :for={c <- @kitty} id={c} /></dd>
        </div>
      </dl>
    </section>
    """
  end

  defp board_settings(assigns) do
    ~H"""
    <section class="rail-card rail-settings" aria-label="Board">
      <h2 class="rail-title">Board</h2>
      <label class="rail-toggle">
        <input
          type="checkbox"
          checked={@reveal}
          phx-click="toggle"
          phx-value-what="reveal"
          disabled={@settings.mode != :analysis}
        />
        <span>Show all hands</span>
      </label>
      <label class="rail-toggle">
        <input
          type="checkbox"
          checked={@control_all}
          phx-click="toggle"
          phx-value-what="control_all"
          disabled={@settings.mode != :analysis}
        />
        <span>Move for every seat</span>
      </label>
      <.strength who="opponents" label="Opponents" value={@settings.opponents} />
      <.strength :if={@setup.variant.teams} who="partner" label="Partner" value={@settings.partner} />
      <div class="rail-actions">
        <button type="button" class="score-button" phx-click="edit_deal">Edit deal</button>
        <button type="button" class="score-button" phx-click="new_game">New game</button>
        <button type="button" class="score-button" id="copy-link" phx-hook="CopyPageLink">Copy link</button>
      </div>
    </section>
    """
  end

  attr :who, :string, required: true
  attr :label, :string, required: true
  attr :value, :atom, required: true

  defp strength(assigns) do
    ~H"""
    <div class="rail-strength" role="group" aria-label={@label}>
      <span>{@label}</span>
      <button
        type="button"
        class={["seg", @value == :site && "seg-on"]}
        aria-pressed={to_string(@value == :site)}
        phx-click="set_strength"
        phx-value-who={@who}
        phx-value-strength="site"
      >Site bot</button>
      <button
        type="button"
        class={["seg", @value == :strong && "seg-on"]}
        aria-pressed={to_string(@value == :strong)}
        phx-click="set_strength"
        phx-value-who={@who}
        phx-value-strength="strong"
      >Strong bot</button>
    </div>
    """
  end

  ## Dialogs: menu, scores, rules, deal editor

  def dialogs(assigns) do
    ~H"""
    <dialog
      :if={@dialog}
      id="game-dialog"
      class="score-overlay"
      phx-hook="GameDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="game-dialog-title"
      role="dialog"
    >
      <div class="dialog-backdrop" phx-click="close_dialog" aria-hidden="true"></div>
      <section class={["game-dialog-panel", @dialog == :editor && "editor-panel"]}>
        <header class="dialog-header">
          <h2 id="game-dialog-title">{dialog_title(@dialog)}</h2>
          <button id="close-score-overlay" type="button" class="score-button" phx-click="close_dialog">Close</button>
        </header>
        <div class="dialog-body">
          <%= case @dialog do %>
            <% :menu -> %>
              <.menu {assigns} />
            <% :scores -> %>
              <.score_table state={@state} />
            <% :rules -> %>
              <.rules variant={@setup.variant} />
            <% :editor -> %>
              <.editor editor={@editor} />
          <% end %>
        </div>
      </section>
    </dialog>
    """
  end

  defp dialog_title(:menu), do: "Menu"
  defp dialog_title(:scores), do: "Scores"
  defp dialog_title(:rules), do: "Quick rules"
  defp dialog_title(:editor), do: "Set up a deal"

  defp menu(assigns) do
    ~H"""
    <div class="menu-list">
      <p class="menu-variant">
        {Variant.label(@setup.variant)} · {if @settings.mode == :play, do: "Play", else: "Analysis"}
      </p>
      <button type="button" class="blue-button" phx-click="new_game">New game</button>
      <button type="button" class="blue-button pass-button" phx-click="rematch">Restart with a new deal</button>
      <button type="button" class="blue-button pass-button" phx-click="edit_deal">Edit this deal</button>
      <button
        :if={@settings.mode == :play and @state.phase != :game_over}
        type="button"
        class="blue-button pass-button"
        phx-click="show_hints"
      >Turn on hints</button>
      <a href="/" class="menu-link">Forty Fives home</a>
    </div>
    """
  end

  attr :state, :map, required: true

  defp score_table(assigns) do
    v = assigns.state.variant
    sides = Variant.sides(v)
    assigns = assign(assigns, v: v, sides: sides, history: Enum.reverse(assigns.state.history))

    ~H"""
    <div class="scoring-panel">
      <div class="score-history" tabindex="0" aria-label="Score history, latest hand first">
        <table>
          <thead>
            <tr>
              <th scope="col">Hand</th>
              <th :for={i <- 0..(@sides - 1)} scope="col">{side_name(@v, i)}</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Now</th>
              <td :for={sc <- @state.scores}><span class="score-total">{minus(sc)}</span></td>
            </tr>
            <tr :for={r <- @history}>
              <th scope="row">{r.hand}</th>
              <td :for={i <- 0..(@sides - 1)}>
                <span class="score-total">{minus(Enum.at(r.scores, i))}</span>
                <span class={["score-change", Enum.at(r.change, i) < 0 && "negative"]}>{signed(
                  Enum.at(r.change, i)
                )}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :variant, :map, required: true

  defp rules(assigns) do
    ~H"""
    <div class="quick-rules">
      <p :if={not @variant.teams}><strong>Cutthroat</strong> {Variant.summary(@variant)}</p>
      <p>
        <strong>Bid</strong>
        15, 20, 25 or 30, then name trump. The dealer may hold the high bid. If everyone passes, the dealer is bagged at 15.
      </p>
      <p>
        <strong>Keep</strong> {if @variant.min_keep > 1, do: "2–5 cards", else: "1–5 cards"}; you're dealt back up to 5. The bid winner also gets the kitty.
      </p>
      <p>
        <strong>Play</strong>
        Follow suit or play trump. The 5, J and A♥ may renege when a lower trump is led.
      </p>
      <p>
        <strong>Score</strong>
        5 a trick, 5 for the highest trump. Miss your bid and lose it. First to 120; if several get there, the bidder wins.
      </p>
      <p>
        <strong>Hints</strong>
        Points are what the trained bot expects for the hand: {if @variant.teams,
          do: "your team's score change minus theirs",
          else: "your score change minus the average of the others'"}. ?! inaccuracy (1.5+ points lost), ? mistake (4+), ?? blunder (8+).
      </p>
      <a href="/learn" target="_blank" rel="noopener">Full rules ↗</a>
    </div>
    """
  end

  ## The deal editor

  attr :editor, :map, required: true

  def editor(assigns) do
    e = assigns.editor
    n = e.variant.n
    owner = for {place, cards} <- e.places, c <- cards, into: %{}, do: {c, place}
    targets = Enum.map(0..(n - 1), &{&1, seat_name(e.variant, &1), 5}) ++ [{:kitty, "Kitty", 3}]
    assigns = assign(assigns, e: e, n: n, owner: owner, targets: targets)

    ~H"""
    <div class="editor">
      <p class="editor-help">
        Pick a seat, then tap its cards. Anything left empty is dealt at random.
      </p>
      <div class="editor-targets" role="tablist" aria-label="Whose cards">
        <button
          :for={{place, name, limit} <- @targets}
          type="button"
          role="tab"
          class={["editor-target", @e.target == place && "editor-target-on"]}
          aria-selected={to_string(@e.target == place)}
          phx-click="editor_target"
          phx-value-target={place}
        >
          <span>{name}</span>
          <span class="editor-count">{length(Map.get(@e.places, place, []))}/{limit}</span>
        </button>
      </div>
      <div class="editor-picked" aria-live="polite">
        <%= case Map.get(@e.places, @e.target, []) do %>
          <% [] -> %>
            <span class="hint-muted">No cards chosen · random</span>
          <% cards -> %>
            <.ctext :for={c <- cards} id={c} />
        <% end %>
      </div>
      <div class="editor-grid">
        <div
          :for={s <- 0..3}
          class="editor-suit"
          role="group"
          aria-label={Enum.at(~w(Hearts Diamonds Clubs Spades), s)}
        >
          <button
            :for={v <- [1, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2]}
            type="button"
            class={[
              "editor-card",
              s in [0, 1] && "suit-red",
              Map.has_key?(@owner, Cards.id(s, v)) && "editor-card-taken",
              @owner[Cards.id(s, v)] == @e.target && "editor-card-mine"
            ]}
            phx-click="editor_card"
            phx-value-card={Cards.id(s, v)}
            aria-pressed={to_string(@owner[Cards.id(s, v)] == @e.target)}
            aria-label={Cards.name(Cards.id(s, v)) <> owner_label(@owner[Cards.id(s, v)], @e.variant)}
          >
            {card_text(Cards.id(s, v))}
            <span
              :if={Map.has_key?(@owner, Cards.id(s, v)) and @owner[Cards.id(s, v)] != @e.target}
              class="editor-owner"
            >{owner_short(@owner[Cards.id(s, v)], @e.variant)}</span>
          </button>
        </div>
      </div>
      <form id="editor-form" class="editor-form" phx-change="editor_form" phx-submit="editor_apply">
        <label>
          <span>Dealer</span>
          <select name="editor[dealer]">
            <option :for={p <- 0..(@n - 1)} value={p} selected={p == @e.dealer}>
              {seat_name(@e.variant, p)}
            </option>
          </select>
        </label>
        <label :for={{sc, i} <- Enum.with_index(@e.scores)}>
          <span>{score_label(@e.variant, i)}</span>
          <input
            type="number"
            name={"editor[score_#{i}]"}
            value={sc}
            min="-995"
            max="995"
            step="5"
            inputmode="numeric"
          />
        </label>
        <div class="editor-buttons">
          <button type="button" class="blue-button pass-button" phx-click="editor_clear">Clear seat</button>
          <button type="button" class="blue-button pass-button" phx-click="editor_clear_all">Clear all</button>
          <button type="submit" class="blue-button editor-start">Deal and play</button>
        </div>
      </form>
    </div>
    """
  end

  defp score_label(%Variant{teams: true}, 0), do: "Your team's score"
  defp score_label(%Variant{teams: true}, 1), do: "Their score"
  defp score_label(_v, 0), do: "Your score"
  defp score_label(v, p), do: "#{seat_name(v, p)}'s score"

  defp owner_label(nil, _v), do: ""
  defp owner_label(:kitty, _v), do: ", in the kitty"
  defp owner_label(p, v), do: ", #{seat_name(v, p)}"

  defp owner_short(:kitty, _v), do: "K"
  defp owner_short(0, _v), do: "Y"
  defp owner_short(p, %{teams: true}), do: Enum.at(~w(Y L P R), p)
  defp owner_short(p, _v), do: Integer.to_string(p)

  ## Starting a game

  attr :form, :map, required: true
  attr :dialog, :atom, default: nil
  attr :editor, :map, default: nil

  def setup_screen(assigns) do
    assigns = assign(assigns, variants: Variant.all())

    ~H"""
    <div id="analysis" class="board board-setup-page">
      <div class="game board-setup">
        <header class="game-header">
          <a href="/" class="game-brand" aria-label="Forty Fives home">
            <img src={~p"/images/logo-mark.png"} alt="Forty Fives" width="44" height="40" />
          </a>
          <div class="game-score"><span class="setup-heading">Practice & analysis</span></div>
          <a href="/play" class="score-button setup-link">Play online</a>
        </header>
        <form id="setup-form" class="setup-form" phx-change="setup_change" phx-submit="start">
          <fieldset class="setup-group">
            <legend>Game</legend>
            <div class="setup-variants">
              <label
                :for={v <- @variants}
                class={["setup-variant", @form["variant"] == v.id && "setup-on"]}
              >
                <input
                  type="radio"
                  name="game[variant]"
                  value={v.id}
                  checked={@form["variant"] == v.id}
                />
                <span class="setup-variant-name">{if v.teams, do: "Partners", else: "Cutthroat #{v.n}"}</span>
                <span class="setup-variant-note">{Variant.summary(v)}</span>
                <span :if={not Advisor.available?(v)} class="setup-variant-note setup-soon">Hints after training</span>
              </label>
            </div>
          </fieldset>
          <fieldset class="setup-group">
            <legend>Mode</legend>
            <div class="setup-modes">
              <label class={["setup-mode", @form["mode"] == "analysis" && "setup-on"]}>
                <input
                  type="radio"
                  name="game[mode]"
                  value="analysis"
                  checked={@form["mode"] == "analysis"}
                />
                <span class="setup-variant-name">Analysis</span>
                <span class="setup-variant-note">See the value of every choice. Take back moves, show all hands, try other cards.</span>
              </label>
              <label class={["setup-mode", @form["mode"] == "play" && "setup-on"]}>
                <input type="radio" name="game[mode]" value="play" checked={@form["mode"] == "play"} />
                <span class="setup-variant-name">Play</span>
                <span class="setup-variant-note">No hints or take-backs. Review every decision when the game ends.</span>
              </label>
            </div>
          </fieldset>
          <fieldset class="setup-group setup-row">
            <legend>Bots</legend>
            <label class={["seg-label", @form["opponents"] == "site" && "setup-on"]}>
              <input
                type="radio"
                name="game[opponents]"
                value="site"
                checked={@form["opponents"] == "site"}
              />
              <span>Site bot</span>
            </label>
            <label class={["seg-label", @form["opponents"] == "strong" && "setup-on"]}>
              <input
                type="radio"
                name="game[opponents]"
                value="strong"
                checked={@form["opponents"] == "strong"}
              />
              <span>Strong bot</span>
            </label>
          </fieldset>
          <fieldset class="setup-group setup-row">
            <legend>First dealer</legend>
            <label
              :for={{value, label} <- [{"random", "Random"}, {"me", "You"}, {"left", "Left of you"}]}
              class={["seg-label", @form["dealer"] == value && "setup-on"]}
            >
              <input
                type="radio"
                name="game[dealer]"
                value={value}
                checked={@form["dealer"] == value}
              />
              <span>{label}</span>
            </label>
          </fieldset>
          <div class="setup-actions">
            <button type="submit" id="start-button" class="blue-button">Deal</button>
            <button
              type="button"
              id="setup-deal-button"
              class="blue-button pass-button"
              phx-click={JS.push("setup_deal", value: %{"game" => @form})}
            >Set up a deal</button>
          </div>
        </form>
      </div>
    </div>
    <dialog
      :if={@dialog == :editor}
      id="game-dialog"
      class="score-overlay"
      phx-hook="GameDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="game-dialog-title"
      role="dialog"
    >
      <div class="dialog-backdrop" phx-click="close_dialog" aria-hidden="true"></div>
      <section class="game-dialog-panel editor-panel">
        <header class="dialog-header">
          <h2 id="game-dialog-title">Set up a deal</h2>
          <button id="close-score-overlay" type="button" class="score-button" phx-click="close_dialog">Close</button>
        </header>
        <div class="dialog-body"><.editor editor={@editor} /></div>
      </section>
    </dialog>
    """
  end
end
