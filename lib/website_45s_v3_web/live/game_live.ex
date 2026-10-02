defmodule Website45sV3Web.GameLive do
  @moduledoc """
  The table view of a running 45s game for one seated player.

  The view only ever holds the per-seat state built by
  `GameController.player_view/2` (own hand, card counts, shared table);
  every action is forwarded to the game process, which validates it.
  """
  use Website45sV3Web, :live_view

  alias Phoenix.LiveView.JS
  alias Website45sV3.Analytics
  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.Card
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.Rules
  alias Website45sV3Web.Presence
  alias Website45sV3Web.SiteTracking

  require Logger

  @bid_values Rules.bid_values()
  @suit_symbols [
    {"hearts", "♥", "red"},
    {"diamonds", "♦", "red"},
    {"clubs", "♣", "black"},
    {"spades", "♠", "black"}
  ]
  @symbols %{hearts: "♥", diamonds: "♦", clubs: "♣", spades: "♠"}

  # Hands are shown trump first, then the other suits alternating colour.
  @suit_display_order %{
    nil => [:hearts, :clubs, :diamonds, :spades],
    hearts: [:hearts, :clubs, :diamonds, :spades],
    diamonds: [:diamonds, :clubs, :hearts, :spades],
    clubs: [:clubs, :hearts, :spades, :diamonds],
    spades: [:spades, :hearts, :clubs, :diamonds]
  }

  @impl true
  def mount(%{"id" => game_id}, session, socket) do
    user_id =
      session["user_id"] ||
        raise "User ID not found in session and no current user assigned."

    with [{game_pid, _}] <- Registry.lookup(Website45sV3.Registry, game_id),
         {:ok, game_state} <- fetch_view(game_pid, game_id, user_id, socket) do
      SiteTracking.track(socket, "game_view", %{game_name: game_id})
      {:ok, seat(socket, game_id, user_id, game_state)}
    else
      # Not seated (or abandoned), or the game is gone: back to the lobby.
      _ ->
        Logger.info("User #{user_id} cannot join game #{game_id}, redirecting to /play")
        {:ok, push_navigate(socket, to: ~p"/play")}
    end
  end

  # Subscribes (and tracks presence) before the state used for the first
  # render is fetched, so an update broadcast in between can't leave the
  # view one state behind.
  defp fetch_view(game_pid, game_id, user_id, socket) do
    with {:ok, _view} <- GameController.get_player_view(game_pid, user_id) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")
        Presence.track(self(), game_id, user_id, %{})
        GameController.get_player_view(game_pid, user_id)
      else
        GameController.get_player_view(game_pid, user_id)
      end
    end
  end

  defp seat(socket, game_id, user_id, game_state) do
    socket
    |> assign(
      game_id: game_id,
      user_id: user_id,
      display_name: game_state.player_map[user_id] || "Anonymous",
      selected_suit: nil,
      selected_bid: nil,
      bid_error: nil,
      overlay_visible: false,
      rules_visible: false,
      # Session replay (see Website45sV3.Analytics). Only a connected socket
      # can receive chunks; the replay row is opened on the first one.
      record_replay: connected?(socket) and Analytics.record_replays?(),
      replay: nil
    )
    |> assign_game_state(game_state)
  end

  # Everything derived from the game state lives here so a refresh and a
  # broadcast render identically (e.g. an already-confirmed discard stays
  # confirmed across a reload).
  defp assign_game_state(socket, game_state) do
    user_id = socket.assigns.user_id

    socket
    |> assign(
      game_state: game_state,
      current_player_id: game_state.current_player_id,
      confirm_discard_clicked:
        game_state.phase == "Discard" and user_id in game_state.received_discards_from,
      auto_playing: game_state.auto_playing,
      dealer: game_state.dealing_player_id == user_id,
      turn_ms_left: turn_ms_left(game_state)
    )
  end

  # Time left before a bot takes this seat over, for the countdown. The game
  # process owns the clock; this is only a reading of it at render time.
  defp turn_ms_left(%{deadline: deadline}) when is_integer(deadline),
    do: max(deadline - System.system_time(:millisecond), 0)

  defp turn_ms_left(_state), do: nil

  @impl true
  def handle_info({:update_state, new_state}, socket) do
    {:noreply, assign_game_state(socket, new_state)}
  end

  def handle_info({:game_crash, _reason}, socket), do: game_crashed(socket)
  def handle_info(:game_crash, socket), do: game_crashed(socket)

  def handle_info(:game_end, socket) do
    {:noreply, push_navigate(socket, to: after_game_path(socket), replace: :replace)}
  end

  # The table's own status line says a bot has the seat; no toast.
  def handle_info(:auto_playing, socket), do: {:noreply, assign(socket, :auto_playing, true)}

  def handle_info(:auto_play_disabled, socket),
    do: {:noreply, assign(socket, :auto_playing, false)}

  # Lobby notices can still arrive on "user:<id>" after the player moved to
  # the table (a private lobby they were in expiring, a late redirect).
  def handle_info(:queue_closed, socket), do: {:noreply, socket}
  def handle_info({:redirect, _url}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp game_crashed(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Game ended unexpectedly")
     |> push_navigate(to: ~p"/play")}
  end

  # Called when the client requests to play a card. The payload contains a
  # single card value in the form of `"10_hearts"`; anything else is ignored.
  @impl true
  def handle_event("play-card", %{"cards" => [card_value]}, socket) do
    case Card.parse(card_value) do
      {:ok, card} ->
        {:noreply, dispatch_game(socket, {:play_card, socket.assigns.user_id, card})}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("play-card", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_discard", %{"cards" => cards_to_keep}, socket)
      when is_list(cards_to_keep) do
    # Only forward well-formed payloads; a malformed card string must never
    # reach (let alone crash) the game process.
    if length(cards_to_keep) in 1..5 and Enum.all?(cards_to_keep, &is_binary/1) do
      socket = dispatch_game(socket, {:confirm_discard, socket.assigns.user_id, cards_to_keep})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("confirm_discard", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_bid", _params, socket) do
    bid = if socket.assigns.game_state.bagged, do: "15", else: socket.assigns.selected_bid
    suit = socket.assigns.selected_suit

    case validate_bid_selection(bid, suit, socket.assigns) do
      {:ok, bid, suit_atom} ->
        socket =
          socket
          |> dispatch_game({:player_bid, socket.assigns.user_id, bid, suit_atom})
          |> assign(selected_suit: nil, selected_bid: nil, bid_error: nil)

        {:noreply, socket}

      {:error, message} ->
        {:noreply, assign(socket, bid_error: message)}
    end
  end

  # Choosing a bid or a suit replaces a selected pass, and the other way
  # round. Like a bid, a pass only goes in on Confirm.
  def handle_event("set_bid_number", %{"bid-number" => bid_number}, socket)
      when bid_number in ["15", "20", "25", "30"] do
    suit = if socket.assigns.selected_suit == "pass", do: nil, else: socket.assigns.selected_suit
    {:noreply, assign(socket, selected_bid: bid_number, selected_suit: suit, bid_error: nil)}
  end

  def handle_event("set_bid_number", _params, socket), do: {:noreply, socket}

  def handle_event("set_bid_suit", %{"bid-suit" => bid_suit}, socket)
      when bid_suit in ["hearts", "diamonds", "clubs", "spades"] do
    bid = if socket.assigns.selected_bid == "0", do: nil, else: socket.assigns.selected_bid
    {:noreply, assign(socket, selected_bid: bid, selected_suit: bid_suit, bid_error: nil)}
  end

  def handle_event("set_bid_suit", _params, socket), do: {:noreply, socket}

  def handle_event("set_bid_pass", _params, socket) do
    {:noreply, assign(socket, selected_bid: "0", selected_suit: "pass", bid_error: nil)}
  end

  def handle_event("toggle_score_overlay", _params, socket) do
    {:noreply,
     assign(socket, overlay_visible: !socket.assigns.overlay_visible, rules_visible: false)}
  end

  def handle_event("toggle_rules_overlay", _params, socket) do
    {:noreply,
     assign(socket, rules_visible: !socket.assigns.rules_visible, overlay_visible: false)}
  end

  def handle_event("close_game_dialog", _params, socket) do
    {:noreply, assign(socket, overlay_visible: false, rules_visible: false)}
  end

  # A submit is dispatched asynchronously. Fetching from the same process
  # after it gives the browser the authoritative result, including rejection.
  def handle_event("refresh_hand", _params, socket) do
    with [{pid, _}] <- Registry.lookup(Website45sV3.Registry, socket.assigns.game_id),
         {:ok, state} <- GameController.get_player_view(pid, socket.assigns.user_id) do
      {:noreply, assign_game_state(socket, state)}
    else
      _ -> {:noreply, push_navigate(socket, to: ~p"/play")}
    end
  end

  def handle_event("exit_game", _params, socket) do
    {:noreply, leave_table(socket, ~p"/play", "game")}
  end

  # A private table's players go back to one shared lobby for another game.
  def handle_event("play_again", _params, socket) do
    {:noreply, leave_table(socket, rematch_path(socket) || ~p"/play", "play_again")}
  end

  def handle_event("resume_control", _params, socket) do
    {:noreply, dispatch_game(socket, {:resume_control, socket.assigns.user_id})}
  end

  # A batch of rrweb events from the SessionRecorder hook. `data` is the
  # JSON array as a string so it is stored without being decoded here; the
  # clicks in it come separately (`clicks`, `now`) for the admin timeline.
  def handle_event("replay_chunk", %{"seq" => seq, "data" => data} = params, socket)
      when is_integer(seq) and is_binary(data) do
    if socket.assigns.record_replay do
      {:noreply, store_replay_chunk(socket, seq, data, params)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("replay_chunk", _params, socket), do: {:noreply, socket}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Leaving for good: free this session for new games. If the game process
  # is still running (final scoring screen), a bot owns the seat from here.
  # The dispatch is async, so also clear the seat record synchronously —
  # the lobby we're navigating to must not show a rejoin banner.
  defp leave_table(socket, path, from) do
    socket = dispatch_game(socket, {:abandon_game, socket.assigns.user_id})
    ActiveGames.remove_player(socket.assigns.user_id)

    SiteTracking.track(socket, "abandon", %{
      game_name: socket.assigns.game_id,
      data: %{from: from, phase: socket.assigns.game_state[:phase]}
    })

    push_navigate(socket, to: path)
  end

  defp after_game_path(socket) do
    (socket.assigns.game_state.phase == "Final Scoring" && rematch_path(socket)) || ~p"/play"
  end

  # The lobby is opened on demand by whichever player gets there first.
  defp rematch_path(socket) do
    with id when is_binary(id) <- socket.assigns.game_state[:rematch_id],
         :ok <- PrivateQueueManager.reopen_queue(id, socket.assigns.user_id) do
      ~p"/play/private/#{id}"
    else
      _ -> nil
    end
  end

  # Rejections that mean no later batch can succeed either.
  @replay_stoppers [
    :replay_too_large,
    :chunk_too_large,
    :replay_gone,
    :invalid_events,
    :too_many_replays
  ]

  # Analytics must never take the table down: whatever goes wrong while
  # storing a batch (a full recording, a pruned replay row, a database that
  # stopped answering) ends this seat's recording, not their game.
  defp store_replay_chunk(socket, seq, data, params) do
    clicks = Analytics.clicks_from_client(params["clicks"], params["now"])

    with {:ok, replay} <- ensure_replay(socket, params),
         {:ok, replay} <- Analytics.append_chunk(replay, seq, data, clicks) do
      assign(socket, replay: replay)
    else
      {:error, reason} when reason in @replay_stoppers ->
        stop_replay(socket, reason)

      {:error, %Ecto.Changeset{} = changeset} ->
        stop_replay(socket, "bad recording metadata #{inspect(changeset.errors)}")

      {:error, reason} ->
        Logger.debug(
          "Replay chunk for game #{socket.assigns.game_id} dropped: #{inspect(reason)}"
        )

        socket
    end
  rescue
    error -> stop_replay(socket, Exception.message(error))
  catch
    :exit, reason -> stop_replay(socket, "exit: #{inspect(reason)}")
  end

  defp stop_replay(socket, why) do
    Logger.warning("Replay for game #{socket.assigns.game_id} stopped: #{why}")
    assign(socket, record_replay: false)
  end

  defp ensure_replay(%{assigns: %{replay: %Analytics.Replay{} = replay}}, _params),
    do: {:ok, replay}

  # A stale batch buffered before disconnect cannot open a recording without
  # its initial snapshot. The reconnected hook will send a fresh sequence 0.
  defp ensure_replay(%{assigns: %{replay: nil}}, %{"seq" => seq}) when seq != 0,
    do: {:error, :missing_initial_chunk}

  defp ensure_replay(socket, params) do
    Analytics.start_replay(%{
      game_name: socket.assigns.game_id,
      player_id: socket.assigns.user_id,
      display_name: socket.assigns.display_name,
      device: params["device"],
      viewport_w: params["w"],
      viewport_h: params["h"]
    })
  end

  # Checks a bid selection the way the game will, so the player gets a
  # message instead of a silently ignored bid.
  defp validate_bid_selection(nil, _suit, _assigns), do: {:error, "Bid or Suit not selected."}
  defp validate_bid_selection(_bid, nil, _assigns), do: {:error, "Bid or Suit not selected."}
  defp validate_bid_selection("0", "pass", _assigns), do: {:ok, "0", :pass}

  defp validate_bid_selection("0", _suit, _assigns),
    do: {:error, "Invalid bid. If you select '0' as your bid, your suit must be 'pass'."}

  defp validate_bid_selection(_bid, "pass", _assigns),
    do: {:error, "Invalid suit. If you select a bid other than '0', your suit cannot be 'pass'."}

  defp validate_bid_selection(bid, suit, assigns) do
    {current_bid, _, _} = assigns.game_state.winning_bid
    suit = parse_suit!(suit)

    with {:ok, value, ^suit} <- Rules.parse_bid(bid, suit),
         true <- Rules.bid_allowed?(value, current_bid, assigns.dealer) do
      {:ok, bid, suit}
    else
      _ -> {:error, "Your bid must be higher than the current bid."}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :teams, team_summary(assigns))

    ~H"""
    <div
      id="game-container"
      class="game"
      phx-hook="SessionRecorder"
      data-record={to_string(@record_replay)}
      data-phase={@game_state.phase}
      data-current-turn={to_string(@user_id == @game_state.current_player_id)}
      data-bagged={to_string(@game_state.bagged)}
      data-current-bid={Integer.to_string(elem(@game_state.winning_bid, 0))}
      data-trump={optional_atom_to_string(@game_state.trump)}
      data-suit-led={optional_atom_to_string(@game_state.suit_led)}
      data-auto-playing={to_string(@auto_playing)}
      data-confirm-discard-clicked={to_string(@confirm_discard_clicked)}
      data-dealer={to_string(@dealer)}
    >
      <header class="game-header">
        <a href="/play" class="game-brand" aria-label="Back to lobby (you can rejoin)">
          <img src={~p"/images/logo-mark.png"} alt="Forty Fives" width="44" height="40" />
        </a>
        <div
          class="game-score"
          aria-label={"Your team #{@teams.you.score}, opponents #{@teams.them.score}"}
        >
          <span>You <strong>{@teams.you.score}</strong></span>
          <span class="score-divider" aria-hidden="true">/</span>
          <span>Them <strong>{@teams.them.score}</strong></span>
        </div>
        <button id="open-scores" type="button" class="score-button" phx-click="toggle_score_overlay">Scores</button>
        <button
          id="open-rules"
          type="button"
          class="score-button"
          phx-click="toggle_rules_overlay"
          aria-label="Quick rules"
        >?</button>
      </header>

      <div class="game-status">
        <h1 class="sr-only">{@game_state.phase}</h1>
        <div class="turn-line">
          <p class="turn-text" aria-live="polite" title={turn_message(assigns)}>
            {turn_message(assigns)}
          </p>
          <span
            id="turn-clock"
            class="turn-clock"
            phx-hook="TurnClock"
            data-ms-left={@turn_ms_left}
            role="timer"
          ></span>
        </div>
        {render_facts(assigns)}
        <p
          id="connection-notice"
          class="connection-notice"
          role="status"
          hidden
          phx-disconnected={JS.show()}
          phx-connected={JS.hide()}
        >
          Reconnecting…
        </p>
      </div>

      <div class="game-play-area">
        <section class="phase-area" aria-label={@game_state.phase}>
          <%= case @game_state.phase do %>
            <% "Bidding" -> %>
              {render_seat_table(assigns)}
              {render_bidding_buttons(assigns)}
            <% "Discard" -> %>
              {render_seat_table(assigns)}
            <% "Playing" -> %>
              {render_played_cards(assigns)}
            <% _ -> %>
              {render_scoring(assigns)}
          <% end %>
        </section>
        <%= if @game_state.phase in ["Bidding", "Discard", "Playing"] do %>
          {render_player_hand(assigns)}
        <% end %>
      </div>
    </div>

    <%= if @overlay_visible or @rules_visible do %>
      <dialog
        id="game-dialog"
        class="score-overlay"
        phx-hook="GameDialog"
        phx-mounted={JS.ignore_attributes(["open"])}
        aria-labelledby="game-dialog-title"
        role="dialog"
      >
        <div class="dialog-backdrop" phx-click="close_game_dialog" aria-hidden="true"></div>
        <section class="game-dialog-panel">
          <header class="dialog-header">
            <h2 id="game-dialog-title">{if @rules_visible, do: "Quick rules", else: "Scores"}</h2>
            <button
              id="close-score-overlay"
              type="button"
              class="score-button"
              phx-click="close_game_dialog"
            >Close</button>
          </header>
          <div class="dialog-body">
            <%= if @rules_visible do %>
              <div class="quick-rules">
                <p>
                  <strong>Bid</strong>
                  15, 20, 25 or 30, then name trump. The dealer may hold the high bid. If everyone passes, the dealer is bagged at 15.
                </p>
                <p>
                  <strong>Keep</strong>
                  1–5 cards; you're dealt back up to 5. The bid winner also gets the kitty.
                </p>
                <p>
                  <strong>Play</strong>
                  Follow suit or play trump. The 5, J and A♥ may renege when a lower trump is led.
                </p>
                <p>
                  <strong>Score</strong>
                  5 a trick, 5 for the highest trump. Miss your bid and lose it. First to 120; if both teams get there, the bidders win.
                </p>
                <a href="/learn" target="_blank" rel="noopener">Full rules ↗</a>
              </div>
            <% else %>
              {render_scoring(Map.put(assigns, :in_dialog, true))}
            <% end %>
          </div>
        </section>
      </dialog>
    <% end %>
    """
  end

  # The facts a player at a real table keeps in their head: the bid to beat
  # (and who deals) while bidding, then trump, the contract and tricks taken.
  defp render_facts(assigns) do
    state = assigns.game_state
    {bid, bidder, suit} = state.winning_bid

    assigns =
      assign(assigns,
        bid: bid,
        bidder: bid > 0 && who(assigns, bidder),
        suit: suit,
        tricks: team_tricks(assigns),
        hand_number: length(state.team_1_history)
      )

    ~H"""
    <%= case @game_state.phase do %>
      <% "Bidding" -> %>
        <p class="game-facts" aria-live="polite">
          <span :if={@bidder} class="facts-main">
            High bid:<span class="facts-name">{@bidder}</span>{@bid} <.suit suit={@suit} />
          </span>
          <span :if={!@bidder}>No bids yet</span>
          <span>Dealer: {who(assigns, @game_state.dealing_player_id)}</span>
        </p>
      <% phase when phase in ["Discard", "Playing"] -> %>
        <p class="game-facts" aria-live="polite">
          <span class="facts-main">
            <span class="trump">Trump <.suit suit={@game_state.trump} /></span>
            ·<span class="facts-name">{@bidder}</span>bid {@bid}
          </span>
          <span :if={phase == "Playing"}>Tricks: You {@tricks.you} · Them {@tricks.them}</span>
        </p>
      <% "Scoring" -> %>
        <p class="game-facts" aria-live="polite">
          <span>Hand {@hand_number}</span>
          <span :if={@bidder} class="facts-main">
            <span class="facts-name">{@bidder}</span>bid {@bid} <.suit suit={@suit} />
          </span>
        </p>
      <% _ -> %>
    <% end %>
    """
  end

  attr :suit, :atom, required: true

  defp suit(assigns) do
    assigns = assign(assigns, :symbol, @symbols[assigns.suit])

    ~H"""
    <span
      :if={@symbol}
      class={["suit", @suit in [:hearts, :diamonds] && "suit-red"]}
      role="img"
      aria-label={Atom.to_string(@suit)}
    >{@symbol}</span>
    """
  end

  defp who(assigns, player_id) do
    if player_id == assigns.user_id, do: "You", else: assigns.game_state.player_map[player_id]
  end

  defp team_tricks(assigns) do
    tricks = assigns.game_state.tricks_won
    teams = team_summary(assigns)
    count = fn team -> Enum.sum(Enum.map(team.players, &Map.get(tricks, &1, 0))) end
    %{you: count.(teams.you), them: count.(teams.them)}
  end

  defp turn_message(%{auto_playing: true}), do: "A bot is playing for you"

  defp turn_message(%{game_state: %{phase: "Discard"}, confirm_discard_clicked: true}),
    do: "Waiting for others"

  defp turn_message(%{game_state: %{phase: "Discard"}}), do: "Choose cards to keep"

  defp turn_message(%{game_state: %{phase: "Scoring"}} = assigns) do
    teams = team_summary(assigns)
    "You #{last_change(teams.you.history)} · Them #{last_change(teams.them.history)}"
  end

  defp turn_message(%{game_state: %{phase: "Final Scoring"}} = assigns) do
    teams = team_summary(assigns)
    {_, bidder, _} = assigns.game_state.winning_bid

    winner =
      teams.you.score >= 120 and
        (teams.them.score < 120 or bidder in teams.you.players)

    if winner, do: "Your team wins!", else: "Opponents win"
  end

  defp turn_message(%{game_state: %{trick_winner_id: winner}} = assigns)
       when is_binary(winner) do
    "#{who(assigns, winner)} won the trick"
  end

  defp turn_message(assigns) do
    case assigns.game_state.current_player_id do
      nil -> ""
      id when id == assigns.user_id -> "Your turn"
      id -> "#{assigns.game_state.player_map[id]}'s turn"
    end
  end

  # The other three players, left to right as they sit: the next to play,
  # your partner across the table, then the player before you.
  defp other_seats(assigns) do
    state = assigns.game_state
    me = Enum.find_index(state.player_ids, &(&1 == assigns.user_id))

    state.player_ids
    |> Enum.with_index()
    |> Enum.map(fn {id, index} ->
      %{
        id: id,
        position: relative_position(me, index),
        name: state.player_map[id],
        bot: id in state.bot_ids,
        on_turn: id == state.current_player_id
      }
    end)
  end

  defp render_seat_table(assigns) do
    seats =
      assigns
      |> other_seats()
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&Map.put(&1, :status, seat_status(assigns.game_state, &1)))

    assigns = assign(assigns, :seats, seats)

    ~H"""
    <div class="seat-table" aria-label="Players">
      <div
        :for={seat <- @seats}
        id={"seat-chip-#{seat.position}"}
        class={["seat-chip", "seat-#{seat.position}", seat.on_turn && "seat-on-turn"]}
      >
        <p class="seat-name">
          <span class="seat-name-text" title={seat.name}>
            {if seat.position == 0, do: "You", else: seat.name}
          </span>
          <span :if={seat.position == 2} class="seat-tag">· partner</span>
          <span :if={seat.bot and seat.position != 0} class="seat-tag">· bot</span>
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

  defp seat_status(%{phase: "Bidding", bids: bids}, seat) do
    case Map.get(bids, seat.id) do
      {0, _} -> :pass
      {bid, suit} -> {:bid, bid, suit}
      nil -> :waiting
    end
  end

  defp seat_status(%{phase: "Discard"} = state, seat) do
    if seat.id in state.received_discards_from, do: :ready, else: :waiting
  end

  defp render_bidding_buttons(assigns) do
    {current_bid, _, _} = assigns.game_state.winning_bid
    is_current_player = assigns.user_id == assigns.game_state.current_player_id

    assigns =
      assigns
      |> assign(:current_bid, current_bid)
      |> assign(:can_control, is_current_player and not assigns.auto_playing)
      |> assign(:can_hold, assigns.dealer and is_current_player and current_bid > 0)
      |> assign(:bid_values, @bid_values)
      |> assign(:suit_symbols, @suit_symbols)
      |> then(fn a ->
        if a.game_state.bagged and is_current_player, do: assign(a, :selected_bid, "15"), else: a
      end)

    ~H"""
    <div class="bidding-panel">
      <p :if={@game_state.bagged and @can_control} class="game-hint">
        You're bagged: choose trump for 15.
      </p>
      <p :if={@can_hold and @can_control and not @game_state.bagged} class="game-hint">
        You can hold at {@current_bid}.
      </p>
      <div class="bid-options">
        <div class="bid-numbers" role="group" aria-label="Bid amount">
          <%= for bid <- @bid_values do %>
            <% available = Rules.bid_allowed?(bid, @current_bid, @dealer) and @can_control %>
            <button
              type="button"
              class={["blue-button", @selected_bid == Integer.to_string(bid) && "active"]}
              phx-click="set_bid_number"
              phx-value-bid-number={bid}
              aria-pressed={to_string(@selected_bid == Integer.to_string(bid))}
              disabled={(@game_state.bagged and bid != 15) or not available}
            >{bid}</button>
          <% end %>
        </div>
        <div class="bid-suits" role="group" aria-label="Trump suit">
          <%= for {suit, symbol, color} <- @suit_symbols do %>
            <button
              type="button"
              class={["suit-button", color == "red" && "red-suit", @selected_suit == suit && "active"]}
              phx-click="set_bid_suit"
              phx-value-bid-suit={suit}
              aria-label={capitalize_first(suit)}
              aria-pressed={to_string(@selected_suit == suit)}
              disabled={not @can_control}
            >{symbol}</button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp bid_selection_complete?(nil, _suit), do: false
  defp bid_selection_complete?(_bid, nil), do: false
  defp bid_selection_complete?("0", suit), do: suit == "pass"
  defp bid_selection_complete?(_bid, suit), do: suit != "pass"

  defp bid_summary(%{bid_error: error}) when is_binary(error), do: error
  defp bid_summary(%{selected_suit: "pass"}), do: "Pass"
  defp bid_summary(%{selected_bid: nil, selected_suit: nil}), do: ""

  defp bid_summary(%{selected_bid: nil, selected_suit: suit}),
    do: "#{symbol(suit)} · choose a bid"

  defp bid_summary(%{selected_bid: bid, selected_suit: nil}), do: "#{bid} · choose trump"
  defp bid_summary(%{selected_bid: bid, selected_suit: suit}), do: "Bid #{bid} #{symbol(suit)}"

  defp symbol(suit), do: @symbols[parse_suit!(suit)]

  # Sorted the way most players hold their cards: trump (with the ace of
  # hearts) first, best to worst, then the other suits by colour.
  defp sort_hand(hand, trump) do
    suits = @suit_display_order[trump]

    Enum.sort_by(hand, fn card ->
      cond do
        trump && Card.trump?(card, trump) ->
          {0, -Card.eval_trump({card.suit, card.value}, trump)}

        # Before trump is named the ace of hearts still outranks its suit.
        Card.ace_of_hearts?(card) ->
          {1 + Enum.find_index(suits, &(&1 == :hearts)), -100}

        true ->
          {1 + Enum.find_index(suits, &(&1 == card.suit)),
           -Card.eval_offsuite({card.suit, card.value})}
      end
    end)
  end

  defp hand_cards(state, locked, my_turn) do
    state.hand
    |> sort_hand(state.trump)
    |> Enum.map(fn card ->
      legal = state.legal_moves == [] or card in state.legal_moves

      %{
        card: card,
        value: card_dom_value(card),
        name: Card.to_string(card),
        playable: not locked and (state.phase != "Playing" or legal),
        # Only cards you may not play on your own turn are dimmed; a hand
        # that is waiting stays readable.
        illegal: state.phase == "Playing" and my_turn and not legal
      }
    end)
  end

  # Whether the hand's cards are out of reach: someone else's turn, a bot
  # in the seat, cards already kept, or the bidding (cards are not chosen).
  defp hand_locked?(assigns, my_turn) do
    state = assigns.game_state

    assigns.auto_playing or assigns.confirm_discard_clicked or
      state.phase == "Bidding" or (state.phase == "Playing" and not my_turn)
  end

  # A bagged dealer's bid is 15; only the suit is theirs to choose.
  defp bagged_bid(%{game_state: %{bagged: true}, selected_suit: suit} = assigns, true)
       when suit != "pass",
       do: assign(assigns, :selected_bid, "15")

  defp bagged_bid(assigns, _my_turn), do: assigns

  defp render_player_hand(assigns) do
    state = assigns.game_state
    my_turn = state.current_player_id == assigns.user_id
    in_control = my_turn and not assigns.auto_playing
    locked = hand_locked?(assigns, my_turn)

    assigns =
      assigns
      |> assign(:cards, hand_cards(state, locked, in_control))
      |> assign(:hand_locked, locked)
      |> assign(:can_bid, in_control)
      |> assign(:selection_version, hand_selection_version(assigns))
      |> bagged_bid(my_turn)

    ~H"""
    <section
      id="player-hand"
      class="hand-panel"
      phx-hook="CardSelection"
      aria-label="Your hand"
      data-phase={@game_state.phase}
      data-locked={to_string(@hand_locked)}
      data-auto-playing={to_string(@auto_playing)}
      data-confirmed={to_string(@confirm_discard_clicked)}
      data-selection-version={@selection_version}
    >
      <div class={["player-hand", length(@cards) > 5 && "player-hand-eight"]}>
        <%= for card <- @cards do %>
          <button
            type="button"
            id={"card-button-#{card.value}"}
            class="card-button"
            data-card={card.value}
            aria-label={card.name}
            aria-pressed="false"
            aria-disabled={to_string(not card.playable)}
            disabled={not card.playable}
          >
            <img
              id={"hand-card-#{card.value}"}
              src={get_image_location({card.card.value, card.card.suit})}
              alt={card.name}
              class={["card", card.illegal && "grayed-out"]}
              data-card-value={card.value}
              draggable="false"
            />
            <span class="card-check" aria-hidden="true">✓</span>
          </button>
        <% end %>
      </div>
      {render_hand_action(assigns)}
    </section>
    """
  end

  # The one action under the hand: Resume while a bot has the seat, Pass and
  # Confirm while bidding, otherwise Confirm Keep or Play Card.
  defp render_hand_action(assigns) do
    ~H"""
    <%= cond do %>
      <% @auto_playing -> %>
        <p class="selection-summary"></p>
        <button
          type="button"
          id="resume-control-overlay"
          class="blue-button hand-action"
          phx-click="resume_control"
          phx-disable-with="Resuming…"
        >Resume playing</button>
      <% @game_state.phase == "Bidding" -> %>
        <p class="selection-summary" aria-live="polite">{bid_summary(assigns)}</p>
        <div class="confirm-bid">
          <button
            type="button"
            id="pass-bid-button"
            class={["blue-button pass-button", @selected_suit == "pass" && "active"]}
            phx-click="set_bid_pass"
            aria-pressed={to_string(@selected_suit == "pass")}
            disabled={not @can_bid or @game_state.bagged}
          >Pass</button>
          <button
            type="button"
            id="confirm-bid-button"
            class="blue-button"
            phx-click="confirm_bid"
            phx-disable-with="Sending…"
            disabled={not @can_bid or not bid_selection_complete?(@selected_bid, @selected_suit)}
          >{if @selected_suit == "pass", do: "Confirm Pass", else: "Confirm Bid"}</button>
        </div>
      <% true -> %>
        <p id="selection-summary" class="selection-summary" aria-live="polite"></p>
        <button
          :if={@game_state.phase == "Discard"}
          type="button"
          id="confirm-discard-button"
          class="blue-button hand-action"
          data-hand-action="confirm_discard"
          disabled
        >Confirm Keep</button>
        <button
          :if={@game_state.phase == "Playing"}
          type="button"
          id="play-card-button"
          class="blue-button hand-action"
          data-hand-action="play-card"
          disabled
        >Play Card</button>
    <% end %>
    """
  end

  defp render_played_cards(assigns) do
    state = assigns.game_state

    seats =
      assigns
      |> other_seats()
      |> Enum.map(fn seat ->
        Map.put(
          seat,
          :card,
          Enum.find_value(state.played_cards, fn p -> if p.player_id == seat.id, do: p.card end)
        )
      end)

    assigns = assign(assigns, :seats, seats)

    ~H"""
    <div class="played-cards">
      <div
        id="table"
        class={["table", @game_state.trick_winner_id && "trick-done"]}
        aria-label="Current trick"
      >
        <div
          :for={seat <- @seats}
          id={"seat-#{seat.position}"}
          class={[
            "player-slot",
            "player-#{seat.position}",
            seat.on_turn && "seat-on-turn",
            seat.id == @game_state.trick_winner_id && "trick-winner"
          ]}
        >
          <p class="player-name">
            <span class="seat-name-text" title={seat.name}>
              {if seat.position == 0, do: "You", else: seat.name}
            </span>
            <span :if={seat.position == 2} class="seat-tag">· partner</span>
            <span :if={seat.bot and seat.position != 0} class="seat-tag">· bot</span>
          </p>
          <%= if seat.card do %>
            <img
              class="card"
              src={get_image_location({seat.card.value, seat.card.suit})}
              alt={"#{seat.name} played the #{Card.to_string(seat.card)}"}
              phx-value-card={card_dom_value(seat.card)}
            />
          <% else %>
            <div class="empty-card" aria-label={"#{seat.name} has not played"}></div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp team_summary(assigns) do
    state = assigns.game_state

    teams =
      [{[0, 2], :team1, state.team_1_history}, {[1, 3], :team2, state.team_2_history}]
      |> Enum.map(fn {seats, key, history} ->
        players = Enum.map(seats, &Enum.at(state.player_ids, &1))

        %{
          players: players,
          names: Enum.map_join(players, ", ", &state.player_map[&1]),
          score: state.team_scores[key],
          history: history
        }
      end)

    {you, [them]} = List.pop_at(teams, Enum.find_index(teams, &(assigns.user_id in &1.players)))
    %{you: you, them: them}
  end

  defp render_scoring(assigns) do
    teams = team_summary(assigns)

    rows =
      zip_longest(teams.you.history, teams.them.history)
      |> Enum.with_index(1)
      |> Enum.reverse()

    assigns =
      assigns
      |> assign(:teams, teams)
      |> assign(:rows, rows)
      |> assign(:in_dialog, Map.get(assigns, :in_dialog, false))
      |> assign(:rematch, assigns.game_state[:rematch_id] != nil)
      |> then(fn a ->
        assign(a, :seconds, if(a.in_dialog, do: nil, else: countdown_seconds(a.game_state.phase)))
      end)

    ~H"""
    <div class="scoring-panel">
      <div class="score-totals">
        <div>
          <span>Your team</span><strong>{@teams.you.score}</strong><small>{@teams.you.names}</small>
        </div>
        <div>
          <span>Opponents</span><strong>{@teams.them.score}</strong><small>{@teams.them.names}</small>
        </div>
      </div>
      <div class="score-history" tabindex="0" aria-label="Score history, latest hand first">
        <table>
          <thead>
            <tr>
              <th scope="col">Hand</th><th scope="col">You</th><th scope="col">Them</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{{you, them}, hand} <- @rows}>
              <th scope="row">{hand}</th>
              <td><.score_cell entry={you} /></td>
              <td><.score_cell entry={them} /></td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="3">No hands scored yet.</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@seconds} class="game-hint">
        {if @game_state.phase == "Final Scoring", do: "Leaving in", else: "Next hand in"}
        <span id="scoring-countdown" phx-hook="ScoringCountdown" data-seconds={@seconds}>{@seconds}</span>s
      </p>
      <div :if={@game_state.phase == "Final Scoring" and not @in_dialog} class="final-actions">
        <button
          :if={@rematch}
          id="play-again-button"
          type="button"
          class="blue-button"
          phx-click="play_again"
        >Play again</button>
        <button
          type="button"
          class={["blue-button", @rematch && "pass-button"]}
          phx-click="exit_game"
        >Back to lobby</button>
      </div>
    </div>
    """
  end

  attr :entry, :string, default: nil

  # A history entry is "<total> <change>", e.g. "35 +15" or "-20 -20".
  defp score_cell(assigns) do
    {total, change} =
      case String.split(assigns.entry || "", " ", parts: 2) do
        [total, change] -> {total, change}
        _ -> {nil, nil}
      end

    assigns = assign(assigns, total: total, change: change)

    ~H"""
    <%= if @total do %>
      <span class="score-total">{minus(@total)}</span>
      <span class={["score-change", String.starts_with?(@change, "-") && "negative"]}>
        {if @change == "0", do: "±0", else: minus(@change)}
      </span>
    <% else %>
      —
    <% end %>
    """
  end

  defp last_change([]), do: "0"

  defp last_change(history) do
    case history |> List.last() |> String.split(" ", parts: 2) do
      [_total, "0"] -> "±0"
      [_total, change] -> minus(change)
      _ -> ""
    end
  end

  defp minus(text), do: String.replace(text, "-", "−")

  # The countdown mirrors the game process' own timers, so it reads the
  # same :game_timings config instead of duplicating the numbers.
  defp countdown_seconds("Scoring"), do: div(GameController.timing(:scoring_display), 1000)

  defp countdown_seconds("Final Scoring"),
    do: div(GameController.timing(:final_scoring_timeout), 1000)

  defp countdown_seconds(_phase), do: nil

  defp zip_longest(list1, list2, default \\ nil) do
    max_length = max(length(list1), length(list2))

    list1_padded = pad_trailing(list1, max_length, default)
    list2_padded = pad_trailing(list2, max_length, default)

    Enum.zip(list1_padded, list2_padded)
  end

  defp pad_trailing(list, target_length, _value) when length(list) >= target_length, do: list

  defp pad_trailing(list, target_length, value) do
    count = target_length - length(list)
    list ++ List.duplicate(value, count)
  end

  defp relative_position(current_player_position, player_position) do
    rem(player_position - current_player_position + 4, 4)
  end

  defp hand_selection_version(assigns) do
    hand_signature = Enum.map_join(assigns.game_state.hand, ",", &card_dom_value/1)

    Enum.join(
      [
        assigns.game_state.phase,
        assigns.game_state.current_player_id || "none",
        hand_signature,
        to_string(assigns.confirm_discard_clicked),
        to_string(assigns.auto_playing)
      ],
      "|"
    )
  end

  defp dispatch_game(socket, message) do
    case GameController.dispatch(socket.assigns.game_id, message) do
      :ok ->
        socket

      {:error, :game_not_found} ->
        socket
        |> put_flash(:error, "Game no longer exists.")
        |> push_navigate(to: ~p"/play")
    end
  end

  defp card_dom_value(%Card{} = card), do: Card.encode(card)

  defp optional_atom_to_string(value) when is_atom(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp optional_atom_to_string(_), do: ""

  def get_image_location({value, suit}) do
    "/images/cards/#{Card.card_to_filename({value, suit})}.png"
  end

  @valid_suits %{
    "hearts" => :hearts,
    "diamonds" => :diamonds,
    "clubs" => :clubs,
    "spades" => :spades
  }

  defp parse_suit!(suit) when is_binary(suit) do
    case Map.fetch(@valid_suits, suit) do
      {:ok, atom} -> atom
      :error -> raise ArgumentError, "invalid suit: #{inspect(suit)}"
    end
  end

  def capitalize_first(str) when is_binary(str) and byte_size(str) > 0 do
    first_char = String.slice(str, 0..0)
    rest_of_string = String.slice(str, 1..-1//1)
    String.upcase(first_char) <> rest_of_string
  end

  def capitalize_first(_), do: ""
end
