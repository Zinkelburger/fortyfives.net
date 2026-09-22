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
  alias Website45sV3.Game.Rules
  alias Website45sV3Web.Presence

  require Logger

  @bid_values Rules.bid_values()
  @suit_symbols [
    {"hearts", "♥", "red"},
    {"diamonds", "♦", "red"},
    {"clubs", "♣", "black"},
    {"spades", "♠", "black"}
  ]

  @impl true
  def mount(%{"id" => game_id}, session, socket) do
    user_id =
      session["user_id"] ||
        raise "User ID not found in session and no current user assigned."

    with [{game_pid, _}] <- Registry.lookup(Website45sV3.Registry, game_id),
         {:ok, game_state} <- fetch_view(game_pid, game_id, user_id, socket) do
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
      overlay_visible: false,
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
      dealer: game_state.dealing_player_id == user_id
    )
    |> stream(:played_cards, played_cards_stream_entries(game_state.played_cards), reset: true)
  end

  @impl true
  def handle_info({:update_state, new_state}, socket) do
    {:noreply, assign_game_state(socket, new_state)}
  end

  def handle_info({:game_crash, _reason}, socket), do: game_crashed(socket)
  def handle_info(:game_crash, socket), do: game_crashed(socket)

  def handle_info(:game_end, socket) do
    {:noreply, push_navigate(socket, to: ~p"/play", replace: :replace)}
  end

  def handle_info(:auto_playing, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "You took too long. A bot is playing for you.")
     |> assign(:auto_playing, true)}
  end

  def handle_info(:auto_play_disabled, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       "Welcome back! A bot was playing for you when you left. Auto-play has been disabled."
     )
     |> assign(:auto_playing, false)}
  end

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
      {:noreply, assign(socket, confirm_discard_clicked: true)}
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
          |> assign(selected_suit: nil, selected_bid: nil)

        {:noreply, socket}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("set_bid_number", %{"bid-number" => bid_number}, socket)
      when bid_number in ["15", "20", "25", "30"] do
    {:noreply, assign(socket, selected_bid: bid_number)}
  end

  def handle_event("set_bid_number", _params, socket), do: {:noreply, socket}

  def handle_event("set_bid_suit", %{"bid-suit" => bid_suit}, socket)
      when bid_suit in ["hearts", "diamonds", "clubs", "spades"] do
    {:noreply, assign(socket, selected_suit: bid_suit)}
  end

  def handle_event("set_bid_suit", _params, socket), do: {:noreply, socket}

  def handle_event("set_bid_pass", _params, socket) do
    socket =
      socket
      |> dispatch_game({:player_bid, socket.assigns.user_id, "0", :pass})
      |> assign(selected_bid: "0", selected_suit: "pass")

    {:noreply, socket}
  end

  def handle_event("toggle_score_overlay", _params, socket) do
    {:noreply, assign(socket, overlay_visible: !socket.assigns.overlay_visible)}
  end

  def handle_event("exit_game", _params, socket) do
    # Leaving for good: free this session for new games. If the game process
    # is still running (final scoring screen), a bot owns the seat from here.
    # The dispatch is async, so also clear the seat record synchronously —
    # the lobby we're navigating to must not show a rejoin banner.
    socket = dispatch_game(socket, {:abandon_game, socket.assigns.user_id})
    ActiveGames.remove_player(socket.assigns.user_id)
    {:noreply, push_navigate(socket, to: ~p"/play")}
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

  # Rejections that mean no later batch can succeed either.
  @replay_stoppers [:replay_too_large, :chunk_too_large, :replay_gone]

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
      <%= if @game_state.phase != "Playing" do %>
        <h1 class="game-state-style">
          {@game_state.phase}
        </h1>
      <% end %>
      <div style="text-align: center;">
        <%= if @game_state.phase == "Playing" do %>
          <div style="display: flex; align-items: center; justify-content: center; gap: 1rem; margin-top: -2rem;">
            <p style="color: #d2e8f9; line-height: 1; font-size: 0.9rem; margin: 0;">
              Trump: {capitalize_first(optional_atom_to_string(@game_state.trump))}
            </p>
            <button type="button" class="score-button" phx-click="toggle_score_overlay">
              View Scores
            </button>
          </div>
        <% end %>

        {render_auto_play_banner(assigns)}

        {render_actions(assigns)}

        {render_phase_content(assigns)}

        {render_player_hand(assigns)}

        <%= if @game_state.phase not in ["Playing", "Scoring", "Final Scoring"] and not @auto_playing do %>
          <button
            type="button"
            class="blue-button"
            phx-click="toggle_score_overlay"
            style="margin-top: 1rem;"
          >
            View Scores
          </button>
        <% end %>
      </div>
    </div>

    <%= if @overlay_visible and @game_state.phase not in ["Scoring", "Final Scoring"] do %>
      <div
        class="score-overlay"
        role="dialog"
        aria-modal="true"
        aria-label="Scores"
        phx-click="toggle_score_overlay"
        phx-window-keydown="toggle_score_overlay"
        phx-key="Escape"
      >
        {render_scoring(assigns)}
        <div style="text-align: center; margin-top: 1rem;">
          <button
            type="button"
            id="close-score-overlay"
            class="blue-button"
            phx-click="toggle_score_overlay"
            phx-mounted={JS.focus()}
          >
            Close
          </button>
        </div>
      </div>
    <% end %>
    """
  end

  defp render_actions(assigns) do
    assigns = assign(assigns, :actions_string, Enum.join(assigns.game_state.actions, ", "))

    ~H"""
    <div class="actions-list" aria-live="polite">
      {@actions_string}
    </div>
    """
  end

  defp render_phase_content(%{game_state: %{phase: "Bidding"}} = assigns),
    do: render_bidding_buttons(assigns)

  defp render_phase_content(%{game_state: %{phase: "Discard"}} = assigns),
    do: render_discard_button(assigns)

  defp render_phase_content(%{game_state: %{phase: "Playing"}} = assigns),
    do: render_played_cards(assigns)

  defp render_phase_content(%{game_state: %{phase: phase}} = assigns)
       when phase in ["Scoring", "Final Scoring"],
       do: render_scoring(assigns)

  defp render_bidding_buttons(assigns) do
    {current_bid, _, _} = assigns.game_state.winning_bid
    is_current_player = assigns.user_id == assigns.game_state.current_player_id
    bagged = assigns.game_state.bagged

    assigns =
      assigns
      |> assign(:current_bid, current_bid)
      |> assign(
        :current_player_name,
        assigns.game_state.player_map[assigns.game_state.current_player_id]
      )
      |> assign(:is_current_player, is_current_player)
      |> assign(:bagged, bagged)
      |> assign(:can_control, is_current_player and not assigns.auto_playing)
      |> assign(:can_hold, assigns.dealer and is_current_player and current_bid > 0)
      |> assign(:bid_values, @bid_values)
      |> assign(:suit_symbols, @suit_symbols)
      # A bagged dealer's only bid is 15.
      |> then(fn assigns ->
        if bagged and is_current_player, do: assign(assigns, :selected_bid, "15"), else: assigns
      end)

    ~H"""
    <div>
      <%= cond do %>
        <% not @is_current_player -> %>
          <p style="color: #d2e8f9; text-align: center; font-size: 1rem;">
            It is {@current_player_name}'s turn
          </p>
        <% @bagged -> %>
          <p style="color: #d2e8f9; text-align: center; font-size: 1rem; font-weight: bold;">
            You are bagged
          </p>
        <% @can_hold -> %>
          <p style="color: #d2e8f9; text-align: center; font-size: 1rem; font-weight: bold;">
            It is your turn. As dealer you may hold at {@current_bid}
          </p>
        <% true -> %>
          <p style="color: #d2e8f9; text-align: center; font-size: 1rem; font-weight: bold;">
            It is your turn
          </p>
      <% end %>
      <!-- Bid options -->
      <div class="bid-options">
        <!-- Number bids -->
        <div class="bid-numbers">
          <%= for bid <- @bid_values do %>
            <% available = Rules.bid_allowed?(bid, @current_bid, @dealer) and @can_control %>
            <button
              type="button"
              class={
                "blue-button" <>
                  if(@selected_bid == Integer.to_string(bid), do: " active", else: "") <>
                  if(available, do: "", else: " grayed-out")
              }
              phx-click="set_bid_number"
              phx-value-bid-number={bid}
              aria-pressed={to_string(@selected_bid == Integer.to_string(bid))}
              disabled={(@bagged and bid != 15) or not available}
            >
              {bid}
            </button>
          <% end %>
        </div>
        <!-- Bid suits -->
        <div class="bid-suits">
          <%= for {suit, symbol, color} <- @suit_symbols do %>
            <button
              type="button"
              class={"blue-button" <> if(@selected_suit == suit, do: " active", else: "")}
              phx-click="set_bid_suit"
              phx-value-bid-suit={suit}
              aria-label={capitalize_first(suit)}
              aria-pressed={to_string(@selected_suit == suit)}
              style={"color: #{color};"}
              disabled={not @can_control}
            >
              {symbol}
            </button>
          <% end %>
        </div>
      </div>
      <!-- Confirm Bid button outside the flex container -->
      <div class="confirm-bid">
        <button
          type="button"
          id="pass-bid-button"
          class="blue-button pass-button"
          style="padding-top: 10px; padding-bottom: 5px; margin-right: 10px;"
          phx-click="set_bid_pass"
          phx-value-bid-number="0"
          phx-value-bid-suit="pass"
          disabled={not @can_control or @bagged}
        >
          Pass
        </button>
        <button
          type="button"
          id="confirm-bid-button"
          class="blue-button"
          style="padding-top: 10px; padding-bottom: 5px;"
          phx-click="confirm_bid"
          disabled={not @can_control or not bid_selection_complete?(@selected_bid, @selected_suit)}
        >
          Confirm Bid
        </button>
      </div>
    </div>
    """
  end

  # A bid and a suit have both been picked, and they agree about passing.
  defp bid_selection_complete?(nil, _suit), do: false
  defp bid_selection_complete?(_bid, nil), do: false
  defp bid_selection_complete?("0", suit), do: suit == "pass"
  defp bid_selection_complete?(_bid, suit), do: suit != "pass"

  defp render_discard_button(assigns) do
    discard_message =
      if assigns.confirm_discard_clicked,
        do: "Waiting for other players...",
        else: "Select the cards you want to keep"

    assigns =
      assigns
      |> assign(:discard_message, discard_message)
      |> assign(:attrs, discard_button_attrs(assigns))

    ~H"""
    <div>
      <p class="discard-message" aria-live="polite">{@discard_message}</p>
      <button
        type="button"
        id="confirm-discard-button"
        class="blue-button"
        phx-hook="ConfirmDiscardButton"
        {@attrs}
      >
        Confirm Keep
      </button>
    </div>
    """
  end

  defp discard_button_attrs(assigns) do
    if assigns.confirm_discard_clicked or assigns.auto_playing do
      [disabled: true]
    else
      []
    end
  end

  # Selection is handled client-side by the CardSelection hook, which listens
  # for clicks bubbling from `img[data-card-value]`. Keyboard users get the
  # same click through a wrapping button: Enter (keydown) and Space (keyup)
  # each dispatch a click on the image itself.
  defp render_player_hand(assigns) do
    game_state = assigns.game_state
    legal_moves = game_state.legal_moves
    hand_locked = assigns.auto_playing or assigns.confirm_discard_clicked
    my_turn = game_state.current_player_id == assigns.user_id

    cards =
      Enum.map(game_state.hand, fn card ->
        legal = legal_moves == [] or card in legal_moves

        playable =
          not (hand_locked or (game_state.phase == "Playing" and (not legal or not my_turn)))

        %{
          card: card,
          value: card_dom_value(card),
          name: Card.to_string(card),
          class: "card" <> if(playable, do: "", else: " grayed-out"),
          playable: playable
        }
      end)

    assigns =
      assigns
      |> assign(:cards, cards)
      |> assign(:selection_version, hand_selection_version(assigns))

    ~H"""
    <div
      id="player-hand"
      class="player-hand"
      role="group"
      aria-label="Your hand"
      phx-hook="CardSelection"
      data-phase={@game_state.phase}
      data-auto-playing={to_string(@auto_playing)}
      data-selection-version={@selection_version}
    >
      <%= for card <- @cards do %>
        <span
          style="display: block;"
          phx-keyup={JS.dispatch("click", to: "#hand-card-#{card.value}")}
          phx-key=" "
        >
          <button
            type="button"
            class="card-button"
            style="background: none; border: 0; padding: 0; margin: 0; display: block; cursor: pointer;"
            aria-label={card.name}
            aria-disabled={to_string(not card.playable)}
            phx-keydown={JS.dispatch("click", to: "#hand-card-#{card.value}")}
            phx-key="Enter"
          >
            <img
              id={"hand-card-#{card.value}"}
              src={get_image_location({card.card.value, card.card.suit})}
              alt={card.name}
              class={card.class}
              data-card-value={card.value}
            />
          </button>
        </span>
      <% end %>
    </div>
    """
  end

  defp render_played_cards(assigns) do
    game_state = assigns.game_state
    current_player_position = Enum.find_index(game_state.player_ids, &(&1 == assigns.user_id))
    is_current_player = assigns.user_id == assigns.current_player_id

    player_names =
      Map.new(game_state.player_ids, fn player_id ->
        {player_id, game_state.player_map[player_id] || "Anonymous"}
      end)

    turn_message =
      case {assigns.current_player_id, is_current_player} do
        {nil, _} -> ""
        {_, true} -> "Your turn"
        {_, false} -> "#{player_names[assigns.current_player_id]}'s turn"
      end

    assigns =
      assigns
      |> assign(:current_player_position, current_player_position)
      |> assign(:is_current_player, is_current_player)
      |> assign(:player_names, player_names)
      |> assign(:turn_message, turn_message)
      |> assign(:attrs, play_card_button_attrs(assigns.auto_playing, is_current_player))

    ~H"""
    <div class="played-cards">
      <p class="turn-text" aria-live="polite">
        {@turn_message}
      </p>
      <div id="table" class="table" phx-update="stream" style="margin-top: -20px;">
        <%= for {dom_id, %{player_id: player_id, card: %Card{} = card}} <- @streams.played_cards do %>
          <% player_position = Enum.find_index(@game_state.player_ids, &(&1 == player_id)) %>
          <% relative_pos = relative_position(@current_player_position, player_position) %>
          <% card_rotation = if relative_pos in [1, 3], do: "rotate", else: "" %>

          <div id={dom_id} class={"player-slot player-#{relative_pos}"}>
            <p class="player-name">{@player_names[player_id]}</p>
            <img
              class={"card #{card_rotation}"}
              src={get_image_location({card.value, card.suit})}
              alt={"#{@player_names[player_id]} played the #{Card.to_string(card)}"}
              phx-value-card={card_dom_value(card)}
            />
          </div>
        <% end %>
      </div>
      <button
        type="button"
        id="play-card-button"
        class="blue-button"
        phx-hook="PlayCardButton"
        {@attrs}
      >
        Play Card
      </button>
    </div>
    """
  end

  defp render_scoring(assigns) do
    game_state = assigns.game_state

    team_players = fn seats ->
      Enum.map_join(seats, ", ", &game_state.player_map[Enum.at(game_state.player_ids, &1)])
    end

    assigns =
      assigns
      |> assign(:team_1_players, team_players.([0, 2]))
      |> assign(:team_2_players, team_players.([1, 3]))
      |> assign(:scores, zip_longest(game_state.team_1_history, game_state.team_2_history))
      |> assign(:seconds, countdown_seconds(game_state.phase))

    ~H"""
    <div style="height: 100vh; align-items: center; justify-content: center;">
      <table style="color: #d2e8f9; max-width: 40%; margin: auto;">
        <caption class="sr-only" style="position: absolute; left: -10000px;">Scores by hand</caption>
        <thead>
          <tr>
            <th scope="col" style="padding: 5px 10px; border-right: 1px solid;">{@team_1_players}</th>
            <th scope="col" style="padding: 5px 10px;">{@team_2_players}</th>
          </tr>
        </thead>
        <tbody>
          <%= for {t1, t2} <- @scores do %>
            <tr>
              <td style="padding: 5px 10px; border-right: 1px solid;">{t1 || ""}</td>
              <td style="padding: 5px 10px;">{t2 || ""}</td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <%= if @seconds do %>
        <div
          id="scoring-countdown"
          phx-hook="ScoringCountdown"
          data-seconds={@seconds}
          style="color: #d2e8f9; text-align: center; margin-top: 1rem;"
        >
          {@seconds}
        </div>
      <% end %>
      <%= if @game_state.phase == "Final Scoring" do %>
        <button type="button" class="blue-button" phx-click="exit_game" style="margin-top: 1rem;">
          Exit
        </button>
      <% end %>
    </div>
    """
  end

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

  defp play_card_button_attrs(auto_playing, is_current_player) do
    if auto_playing or not is_current_player, do: [disabled: true], else: []
  end

  defp render_auto_play_banner(assigns) do
    ~H"""
    <%= if @auto_playing do %>
      <button
        type="button"
        id="resume-control-overlay"
        phx-click="resume_control"
        phx-mounted={JS.focus()}
        aria-label="Resume playing"
        style="position: fixed; inset: 0; z-index: 1100; cursor: pointer; background: transparent; border: 0; padding: 0;"
      ></button>
      <div style="margin: 1rem auto; max-width: 24rem;">
        <p style="color: #d2e8f9; margin-bottom: 0.75rem;" aria-live="polite">
          A bot is playing your seat.<br />Click anywhere to take back control.
        </p>
      </div>
    <% end %>
    """
  end

  defp played_cards_stream_entries(played_cards) do
    Enum.map(played_cards, fn %{card: %Card{} = card, player_id: player_id} ->
      %{id: "#{card_dom_value(card)}_#{player_id}", card: card, player_id: player_id}
    end)
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
