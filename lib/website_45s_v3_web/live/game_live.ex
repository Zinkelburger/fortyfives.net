defmodule Website45sV3Web.GameLive do
  use Website45sV3Web, :live_view
  alias Website45sV3Web.Presence
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.Card

  import Phoenix.LiveView

  def mount(%{"id" => game_id}, session, socket) do
    IO.inspect(session, label: "Session data")
    user_id =
      if session["user_id"] do
        session["user_id"]
      else
        raise "User ID not found in session and no current user assigned."
      end

    case Registry.lookup(Website45sV3.Registry, game_id) do
      [{game_pid, _}] ->
        # Check if the user is in the game
        game_state = GameController.get_game_state(game_pid)
        IO.inspect(game_state.player_ids, label: "Game State Player IDs")

        if user_id in game_state.player_ids do
          display_name = game_state.player_map[user_id] || "Anonymous"

          if connected?(socket) do
            Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")
            Presence.track(self(), game_id, user_id, %{})
          end

          played_cards_with_id = Enum.map(game_state.played_cards, fn %{card: %Website45sV3.Game.Card{value: value, suit: suit}, player_id: player_id} ->
            %{id: "#{value}_#{suit}", card: %Website45sV3.Game.Card{value: value, suit: suit}, player_id: player_id}
          end)

          auto_playing = MapSet.member?(game_state.bot_players, user_id)

          {:ok,
           socket
           |> assign(
             game_id: game_id,
             game_state: game_state,
             selected_suit: nil,
             selected_bid: nil,
             user_id: user_id,
             display_name: display_name,
             confirm_discard_clicked: false,
             current_player_id: game_state[:current_player_id],
             overlay_visible: false,
             game_over: false,
             auto_playing: auto_playing
           )
           |> stream(:played_cards, played_cards_with_id)}
        else
          # If the user is not in the game, redirect them back to the queue page
          IO.puts("User #{user_id} not in game, redirecting to /play")
          {:ok, push_navigate(socket, to: "/play")}
        end

      _ ->
        # If the game does not exist, redirect them back to the queue page
        IO.puts("Game does not exist, redirecting to /play")
        {:ok, push_navigate(socket, to: "/play")}
    end
  end

  def handle_info({:update_state, new_state}, socket) do
    current_player_id = new_state[:current_player_id]

    played_cards_with_id = Enum.map(new_state.played_cards, fn %{card: %Website45sV3.Game.Card{value: value, suit: suit}, player_id: player_id} ->
      %{id: "#{value}_#{suit}_#{player_id}", card: %Website45sV3.Game.Card{value: value, suit: suit}, player_id: player_id}
    end)

    confirm_discard_clicked =
      if new_state.phase == "Discard" do
        socket.assigns.user_id in new_state.received_discards_from
      else
        false
      end

    socket =
      socket
      |> assign(:game_state, new_state)
      |> assign(:current_player_id, current_player_id)
      |> assign(:confirm_discard_clicked, confirm_discard_clicked)

    if new_state.phase == "Playing" do
      if played_cards_with_id == [] do
        {:noreply, stream(socket, :played_cards, [], reset: true)}
      else
        socket = Enum.reduce(played_cards_with_id, socket, fn card, acc ->
          stream_insert(acc, :played_cards, card, at: -1)
        end)

        {:noreply, socket}
      end
    else
      {:noreply, stream(socket, :played_cards, played_cards_with_id, reset: true)}
    end
  end

  def handle_info(:game_crash, socket) do
    # when the GameController crashes
    socket = assign(socket, :game_over, true)
    {:noreply, push_navigate(socket |> put_flash(:error, "Game ended unexpectedly"), to: "/play")}
  end

  def handle_info(:game_end, socket) do
    socket = assign(socket, :game_over, true)
    {:noreply, push_navigate(socket, to: "/play", replace: :replace)}
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

  @doc """
  Called when the client requests to play a card. The payload contains a single
  card value in the form of `"10_hearts"`. We parse the value and broadcast an
  instruction to the running game process.
  """
  def handle_event("play-card", %{"cards" => [card_value]}, socket) do
    with [value, suit] <- String.split(card_value, "_"),
         {int_val, suit_atom} <- parse_card_string([value, suit]) do
      card = %Website45sV3.Game.Card{value: int_val, suit: suit_atom}

      Phoenix.PubSub.broadcast(
        Website45sV3.PubSub,
        socket.assigns.game_state.game_name,
        {:play_card, socket.assigns.user_id, card}
      )
    end

    {:noreply, socket}
  end

  def handle_event("play-card", _params, socket), do: {:noreply, socket}

  @doc """
  Receive the list of cards the player chose to keep during the discard phase
  and notify the running game. The client sends the cards in order of
  appearance from the CardSelection hook.
  """
  def handle_event("confirm_discard", %{"cards" => cards_to_keep}, socket) do
    Phoenix.PubSub.broadcast(
      Website45sV3.PubSub,
      socket.assigns.game_state.game_name,
      {:confirm_discard, socket.assigns.user_id, cards_to_keep}
    )

    {:noreply, assign(socket, confirm_discard_clicked: true)}
  end

  def handle_event("confirm_bid", _params, socket) do
    current_bid =
      if socket.assigns.game_state.bagged do
        "15"
      else
        socket.assigns.selected_bid
      end

    current_suit = socket.assigns.selected_suit
    current_player_id = socket.assigns.user_id
    {game_current_bid_value, _, _} = socket.assigns.game_state.winning_bid

    # Validate the bid
    cond do
      current_bid == nil or current_suit == nil ->
        {:noreply, socket |> put_flash(:error, "Bid or Suit not selected.")}

      current_bid == "0" and current_suit != "pass" ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Invalid bid. If you select '0' as your bid, your suit must be 'pass'."
         )}

      current_bid != "0" and current_suit == "pass" ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Invalid suit. If you select a bid other than '0', your suit cannot be 'pass'."
         )}

      current_bid != "0" and String.to_integer(current_bid) <= game_current_bid_value ->
        {:noreply, socket |> put_flash(:error, "Your bid must be higher than the current bid.")}

      true ->
        # Broadcast the bid information
        suit_atom =
          case current_suit do
            "pass" -> :pass
            _ -> String.to_existing_atom(current_suit)
          end

        Phoenix.PubSub.broadcast(
          Website45sV3.PubSub,
          socket.assigns.game_state.game_name,
          {:player_bid, current_player_id, current_bid, suit_atom}
        )

        # Clear the assigns for selected_suit and selected_bid
        updated_socket =
          socket
          |> assign(:selected_suit, nil)
          |> assign(:selected_bid, nil)

        {:noreply, updated_socket}
    end
  end

  def handle_event("set_bid_number", %{"bid-number" => bid_number}, socket) do
    {:noreply, assign(socket, selected_bid: bid_number)}
  end

  def handle_event("set_bid_suit", %{"bid-suit" => bid_suit}, socket) do
    {:noreply, assign(socket, selected_suit: bid_suit)}
  end

  def handle_event("set_bid_pass", %{"bid-suit" => "pass"}, socket) do
    new_assigns = %{selected_bid: "0", selected_suit: "pass"}

    Phoenix.PubSub.broadcast(
      Website45sV3.PubSub,
      socket.assigns.game_state.game_name,
      {:player_bid, socket.assigns.user_id, "0", :pass}
    )

    {:noreply, assign(socket, new_assigns)}
  end


  def handle_event("toggle_score_overlay", _params, socket) do
    {:noreply, assign(socket, overlay_visible: !socket.assigns.overlay_visible)}
  end

  def handle_event("exit_game", _params, socket) do
    {:noreply, push_navigate(socket, to: "/play")}
  end

  def handle_event("resume_control", _params, socket) do
    Phoenix.PubSub.broadcast(
      Website45sV3.PubSub,
      socket.assigns.game_state.game_name,
      {:resume_control, socket.assigns.user_id}
    )

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    unless socket.assigns[:game_over] do
      Phoenix.PubSub.broadcast(
        Website45sV3.PubSub,
        "user:#{socket.assigns.user_id}",
        {:left_game, socket.assigns.game_id}
      )
    end

    :ok
  end

  def render(assigns) do
    ~H"""
    <div class="game">
      <%= if assigns.game_state.phase != "Playing" do %>
        <h1 class="game-state-style">
          <%= assigns.game_state.phase %>
        </h1>
      <% end %>
      <div style="text-align: center;">
          <%= if assigns.game_state.phase == "Playing" do %>
            <div style="display: flex; align-items: center; justify-content: center; gap: 1rem; margin-top: -2rem;">
              <p style="color: #d2e8f9; line-height: 1; font-size: 0.9rem; margin: 0;">
                Trump: <%= capitalize_first(Atom.to_string(assigns.game_state.trump)) %>
              </p>
              <button
                class="score-button"
                phx-click="toggle_score_overlay"
              >
                View Scores
              </button>
            </div>
          <% end %>

        <%= render_actions(assigns) %>

        <%= render_phase_content(assigns) %>

        <%= render_player_hand(assigns) %>

        <%= if assigns.game_state.phase not in ["Playing", "Scoring", "Final Scoring"] do %>
          <%= if @auto_playing do %>
            <button class="blue-button" phx-click="resume_control" style="margin-top: 1rem;">Resume Game!</button>
          <% else %>
            <button class="blue-button" phx-click="toggle_score_overlay" style="margin-top: 1rem;">
              View Scores
            </button>
          <% end %>
        <% end %>
      </div>
    </div>

    <%= if @overlay_visible and @game_state.phase not in ["Scoring", "Final Scoring"] do %>
      <div class="score-overlay" phx-click="toggle_score_overlay">
        <%= render_scoring(assigns) %>
      </div>
    <% end %>
    """
  end

  defp render_actions(assigns) do
    actions_string = Enum.join(assigns.game_state.actions, ", ")
    assigns = assign(assigns, :actions_string, actions_string)

    ~H"""
    <div class="actions-list">
      <%= @actions_string %>
    </div>
    """
  end

  defp render_phase_content(assigns) do
    case assigns.game_state.phase do
      "Bidding" -> render_bidding_buttons(assigns)
      "Discard" -> render_discard_button(assigns)
      "Playing" -> render_played_cards(assigns)
      "Scoring" -> render_scoring(assigns)
      "Final Scoring" -> render_scoring(assigns)
      _ -> "Invalid phase"
    end
  end

  defp render_bidding_buttons(assigns) do
    assigns =
      assigns
      |> assign(:current_bid, elem(assigns.game_state.winning_bid, 0))
      |> assign(:current_player_id, assigns.game_state.current_player_id)
      |> assign(:current_player_name, assigns.game_state.player_map[assigns.game_state.current_player_id])
      |> assign(
        :is_current_player,
        assigns.user_id == assigns.game_state.current_player_id
      )
      |> assign(:bagged, assigns.game_state.bagged)

    # If the player is bagged, set selected_bid to 15
    assigns =
      if assigns.bagged && assigns.is_current_player do
        assign(assigns, :selected_bid, "15")
      else
        assigns
      end

    ~H"""
    <div>
      <%= if not @is_current_player do %>
        <p style="color: #d2e8f9; text-align: center; font-size: 1rem;">It is <%= @current_player_name %>'s turn</p>
      <% else %>
        <%= if @bagged do %>
          <p style="color: #d2e8f9; text-align: center; font-size: 1rem; font-weight: bold;">You are bagged</p>
        <% else %>
          <p style="color: #d2e8f9; text-align: center; font-size: 1rem; font-weight: bold;">It is your turn</p>
        <% end %>
      <% end %>
      <!-- Bid options -->
      <div class="bid-options">
        <!-- Number bids -->
        <div class="bid-numbers">
          <%= for bid <- [15, 20, 25, 30] do %>
            <button
              class={
                  "blue-button" <>
                  (if assigns.selected_bid == Integer.to_string(bid), do: " active", else: "") <>
                  (if bid_available?(@current_bid, bid) and @is_current_player, do: "", else: " grayed-out")
                }
              phx-click="set_bid_number"
              phx-value-bid-number={bid}
              disabled={
                (@bagged and bid != 15) or not bid_available?(@current_bid, bid) or
                  not @is_current_player
              }
            >
              <%= bid %>
            </button>
          <% end %>
        </div>
        <!-- Bid suits -->
        <div class="bid-suits">
          <button
            class={"blue-button" <> if assigns.selected_suit == "hearts", do: " active", else: ""}
            phx-click="set_bid_suit"
            phx-value-bid-suit="hearts"
            style="color: red;"
            disabled={not @is_current_player}
          >
            ♥
          </button>
          <button
            class={"blue-button" <> if assigns.selected_suit == "diamonds", do: " active", else: ""}
            phx-click="set_bid_suit"
            phx-value-bid-suit="diamonds"
            style="color: red;"
            disabled={not @is_current_player}
          >
            ♦
          </button>
          <button
            class={"blue-button" <> if assigns.selected_suit == "clubs", do: " active", else: ""}
            phx-click="set_bid_suit"
            phx-value-bid-suit="clubs"
            style="color: black;"
            disabled={not @is_current_player}
          >
            ♣
          </button>
          <button
            class={"blue-button" <> if assigns.selected_suit == "spades", do: " active", else: ""}
            phx-click="set_bid_suit"
            phx-value-bid-suit="spades"
            style="color: black;"
            disabled={not @is_current_player}
          >
            ♠
          </button>
        </div>
      </div>
      <!-- Confirm Bid button outside the flex container -->
      <div class="confirm-bid">
        <button
          class="blue-button pass-button"
          style="padding-top: 10px; padding-bottom: 5px; margin-right: 10px;"
          phx-click="set_bid_pass"
          phx-value-bid-number="0"
          phx-value-bid-suit="pass"
          disabled={not @is_current_player or @bagged}
        >
          Pass
        </button>
        <button
          class="blue-button"
          style="padding-top: 10px; padding-bottom: 5px;"
          phx-click="confirm_bid"
          disabled={
            not @is_current_player or
              assigns.selected_bid == nil or
              assigns.selected_suit == nil or
              (Integer.parse(assigns.selected_bid) |> elem(0) == 0 and assigns.selected_suit != "pass") or
              (Integer.parse(assigns.selected_bid) |> elem(0) != 0 and assigns.selected_suit == "pass")
          }
        >
          Confirm Bid
        </button>
      </div>
    </div>
    """
  end

  defp bid_available?(current_bid, bid) when is_binary(current_bid) do
    bid_available?(String.to_integer(current_bid), bid)
  end

  defp bid_available?(current_bid, bid), do: bid > current_bid

  defp render_discard_button(assigns) do
    discard_message =
      if assigns.confirm_discard_clicked,
        do: "Waiting for other players...",
        else: "Select the cards you want to keep"

    assigns = assign(assigns, :discard_message, discard_message)

    attrs = discard_button_attrs(assigns)
    assigns = assign(assigns, :attrs, attrs)

    ~H"""
    <div>
      <p class="discard-message"><%= @discard_message %></p>
      <button id="confirm-discard-button" class="blue-button" phx-hook="ConfirmDiscardButton" {@attrs}>Confirm Keep</button>
    </div>
    """
  end

  defp discard_button_attrs(assigns) do
    if assigns.confirm_discard_clicked do
      [disabled: true]
    else
      []
    end
  end

  defp render_player_hand(assigns) do
    ~H"""
    <div id="player-hand" class="player-hand" phx-hook="CardSelection" data-phase={@game_state.phase}>
      <%= for %Website45sV3.Game.Card{value: value, suit: suit} <- assigns.game_state.hands[assigns.user_id] do %>
        <% card_value = Integer.to_string(value) <> "_" <> Atom.to_string(suit) %>
        <% legal_moves = Map.get(assigns.game_state.legal_moves, assigns.user_id, []) %>
        <% legal_card_tuples =
          Enum.map(legal_moves, fn %Website45sV3.Game.Card{value: v, suit: s} -> {v, s} end) %>
        <% is_legal_moves_empty = Enum.empty?(legal_moves) %>
        <% is_playing_phase = assigns.game_state.phase == "Playing" %>
        <% is_current_player_turn = assigns.game_state.current_player_id == assigns.user_id %>
        <% is_card_legal = is_legal_moves_empty || {value, suit} in legal_card_tuples %>
        <% card_class =
          "card" <>
            if is_playing_phase && (!is_card_legal || !is_current_player_turn),
              do: " grayed-out",
              else: "" %>

        <img
          src={get_image_location({value, suit})}
          class={card_class}
          data-card-value={card_value}
        />
      <% end %>
    </div>
    """
  end

  defp render_played_cards(assigns) do
    current_player_position = Enum.find_index(assigns.game_state.player_ids, fn player_id ->
      player_id == assigns.user_id
    end)

    is_current_player = assigns.user_id == assigns.current_player_id

    player_names = Enum.map(assigns.game_state.player_ids, fn player_id ->
      {player_id, assigns.game_state.player_map[player_id] || "Anonymous"}
    end) |> Map.new()

    turn_message = case {assigns.current_player_id, is_current_player} do
      {nil, _} -> ""
      {_, true} -> "Your turn"
      {_, false} -> "#{player_names[assigns.current_player_id]}'s turn"
    end

    card_led_suit =
      case assigns.game_state.played_cards do
        [%{card: %Website45sV3.Game.Card{suit: suit}} | _] -> Atom.to_string(suit)
        _ -> ""
      end

    assigns = assigns
      |> assign(:current_player_position, current_player_position)
      |> assign(:is_current_player, is_current_player)
      |> assign(:player_names, player_names)
      |> assign(:turn_message, turn_message)
      |> assign(:card_led_suit, card_led_suit)

    attrs = play_card_button_attrs(assigns)
    assigns = assign(assigns, :attrs, attrs)

    ~H"""
    <div class="played-cards">
      <p class="turn-text">
        <%= @turn_message %>
      </p>
      <div id="table" class="table" phx-update="stream" style="margin-top: -20px;">
        <%= for {dom_id, %{player_id: player_id, card: %Website45sV3.Game.Card{value: value, suit: suit}}} <- @streams.played_cards do %>
          <% player_name = @player_names[player_id] %>
          <% player_position = Enum.find_index(@game_state.player_ids, fn id -> id == player_id end) %>
          <% relative_pos = relative_position(@current_player_position, player_position) %>
          <% card_rotation = if relative_pos in [1, 3], do: "rotate", else: "" %>

          <div id={dom_id} class={"player-slot player-#{relative_pos}"}>
            <p class="player-name"><%= player_name %></p>
            <img
              class={"card #{card_rotation}"}
              src={get_image_location({value, suit})}
              phx-value-card={Integer.to_string(value) <> "_" <> Atom.to_string(suit)}
            />
          </div>
        <% end %>
      </div>
      <%= if @auto_playing do %>
        <button class="blue-button" phx-click="resume_control">Resume Game!</button>
      <% else %>
        <button class="blue-button" phx-hook="PlayCardButton" {@attrs}>
          Play Card
        </button>
      <% end %>
      <div id="card-led-suit" style="display: none;"><%= @card_led_suit %></div>
    </div>
    """
  end

  defp render_scoring(assigns) do
      team_1_players =
        Enum.map([Enum.at(assigns.game_state.player_ids, 0), Enum.at(assigns.game_state.player_ids, 2)], fn id ->
          assigns.game_state.player_map[id]
        end)
        |> Enum.join(", ")

      team_2_players =
        Enum.map([Enum.at(assigns.game_state.player_ids, 1), Enum.at(assigns.game_state.player_ids, 3)], fn id ->
          assigns.game_state.player_map[id]
        end)
        |> Enum.join(", ")

    scores = zip_longest(assigns.game_state.team_1_history, assigns.game_state.team_2_history)

    assigns =
      assign(assigns, :team_1_players, team_1_players)
      |> assign(:team_2_players, team_2_players)
      |> assign(:scores, scores)

    seconds =
      case assigns.game_state.phase do
        "Scoring" -> 6
        "Final Scoring" -> 60
        _ -> nil
      end

    ~H"""
    <div style="height: 100vh; align-items: center; justify-content: center;">
      <%= if @auto_playing do %>
        <button class="blue-button" phx-click="resume_control" style="margin-bottom: 1rem;">Resume Game!</button>
      <% end %>
      <table style="color: #d2e8f9; max-width: 40%; margin: auto;">
        <thead>
          <tr>
            <th style="padding: 5px 10px; border-right: 1px solid;"><%= @team_1_players %></th>
            <th style="padding: 5px 10px;"><%= @team_2_players %></th>
          </tr>
        </thead>
        <tbody>
          <%= for {t1, t2} <- @scores do %>
            <tr>
              <td style="padding: 5px 10px; border-right: 1px solid;"><%= t1 || "" %></td>
              <td style="padding: 5px 10px;"><%= t2 || "" %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <%= if seconds do %>
        <div id="scoring-countdown" phx-hook="ScoringCountdown" data-seconds={seconds} style="color: #d2e8f9; text-align: center; margin-top: 1rem;">
          <%= seconds %>
        </div>
      <% end %>
      <%= if @game_state.phase == "Final Scoring" do %>
        <button class="blue-button" phx-click="exit_game" style="margin-top: 1rem;">Exit</button>
      <% end %>
    </div>
    """
  end

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

  defp play_card_button_attrs(assigns) do
    cond do
      assigns.auto_playing -> []
      not assigns.is_current_player -> [disabled: true]
      true -> []
    end
  end

  def get_image_location({value, suit}) do
    "/images/cards/#{Card.card_to_filename({value, suit})}.png"
  end

  defp parse_card_string([value, suit]) do
    {String.to_integer(value), String.to_atom(suit)}
  end

  def capitalize_first(str) when is_binary(str) and byte_size(str) > 0 do
    first_char = String.slice(str, 0..0)
    rest_of_string = String.slice(str, 1..-1//1)
    String.upcase(first_char) <> rest_of_string
  end
end
