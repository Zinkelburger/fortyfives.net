defmodule Website45sV3.Game.GameController do
  use GenServer
  alias Deck
  alias Suit
  alias Website45sV3.Game.Card

  def start_game(game_name, players) do
    GenServer.start_link(__MODULE__, {game_name, players})
  end

  def init({game_name, players}) do
    case Registry.register(Website45sV3.Registry, game_name, []) do
      {:ok, _pid} ->
        state =
          setup_game(players, Enum.random(players))
          |> Map.put(:team_scores, %{team1: 0, team2: 0})
          |> Map.put(:team_1_history, [])
          |> Map.put(:team_2_history, [])
          |> Map.put(:game_name, game_name)

        Phoenix.PubSub.subscribe(Website45sV3.PubSub, game_name)
        {:ok, state}

      {:error, {:already_registered, _pid}} ->
        {:stop, {:already_registered, game_name}}
    end
  end

  defp setup_game(players, starting_player \\ nil) do
    deck = Deck.new() |> Deck.shuffle(5)
    {hands, deck} = deal_cards(players, deck, 5)

    starting_player =
      case starting_player do
        nil ->
          # If no starting player is provided, rotate to determine the next one
          [first_player | remaining_players] = players
          List.first(remaining_players ++ [first_player])

        starting_player ->
          # Use the provided starting player
          starting_player
      end

    %{
      phase: "Bidding",
      current_player: starting_player,
      dealing_player: starting_player,
      players: players,
      hands: hands,
      legal_moves: %{},
      deck: deck,
      discardDeck: [],
      actions: [],
      winning_bid: {0, nil, nil},
      active_players: [],
      recieved_discards_from: [],
      bagged: false,
      suit_led: nil,
      trump: nil,
      played_cards: [],
      trick_winning_cards: [],
      round_scores: %{team1: 0, team2: 0}
    }
  end

  defp deal_cards(players, deck, num_cards) when is_list(players) do
    Enum.reduce(players, {Map.new(), deck}, fn player, {hands, deck} ->
      {hand, deck} = draw_cards(deck, num_cards)
      {Map.put(hands, player, hand), deck}
    end)
  end

  defp deal_cards(player, deck, num_cards) when is_binary(player) do
    {hand, new_deck} = draw_cards(deck, num_cards)
    {%{player => hand}, new_deck}
  end

  defp draw_cards(deck, num_cards) do
    Enum.reduce(1..num_cards, {[], deck}, fn _, {hand, deck} ->
      {card, deck} = Deck.remove_card(deck)
      {[card | hand], deck}
    end)
  end

  def handle_call(:get_game_state, _from, state), do: {:reply, state, state}

  def get_game_state(pid), do: GenServer.call(pid, :get_game_state)

  def terminate(reason, state) do
    IO.puts(
      "Terminating GameController with reason: #{inspect(reason)} and state: #{inspect(state)}"
    )

    # Notify all players to leave the game
    for player <- state.players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player}", :leave_game)
    end

    :ok
  end

  def handle_info({:play_card, player, card}, state) do
    # Convert string suit to atom if it's a string
    card =
      if is_binary(card.suit) do
        %{card | suit: String.to_atom(card.suit)}
      else
        card
      end

    # 1. Remove the card from the player's hand
    current_hand = Map.get(state.hands, player, [])
    new_hand = List.delete(current_hand, card)
    updated_hands = Map.put(state.hands, player, new_hand)

    # 2. Add the played card with player information to the played_cards
    played_cards_entry = %{player: player, card: card}
    updated_played_cards = [played_cards_entry | state.played_cards || []]

    # Only calculate legal moves if it's the first card played in this trick
    legal_moves =
      if Enum.empty?(state.played_cards) do
        calculate_legal_moves(state, card)
      else
        state.legal_moves
      end

    # set the suit led if there are no cards played
    suit_led =
      case state.played_cards do
        [] -> card.suit
        _ -> state.suit_led
      end

    # Increment the current player to the next player
    current_player_index = Enum.find_index(state.players, fn p -> p == state.current_player end)
    next_player = Enum.at(state.players, rem(current_player_index + 1, 4))

    # Construct the new state
    new_state = %{
      state
      | hands: updated_hands,
        played_cards: updated_played_cards,
        suit_led: suit_led,
        current_player: next_player,
        legal_moves: legal_moves
    }

    # Check if 4 cards have been played
    new_state =
      if length(updated_played_cards) >= 4 do
        {winning_player, highest_card, updated_state_with_scores} =
          evaluate_played_cards(new_state)

        # if it is not the last trick, end the bid
        # if it is the last trick, handle_scoring_phase has you covered
        if length(state.trick_winning_cards) < 5 do
          Process.send_after(self(), {:transition_to_end_bid, winning_player}, 2000)
        end

        # Reset for the next trick and merge updated scores
        %{
          updated_state_with_scores
          | current_player: nil,
            actions:
              updated_state_with_scores.actions ++
                ["#{winning_player} won trick #{length(state.trick_winning_cards) + 1}"],
            trick_winning_cards: [
              %{player: winning_player, card: highest_card.card} | state.trick_winning_cards || []
            ],
            legal_moves: %{}
        }
      else
        new_state
      end

    new_state =
      if length(new_state.trick_winning_cards) == 5 do
        handle_scoring_phase(new_state)
      else
        new_state
      end

    # Broadcasting the updated state to the players
    for p <- state.players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end

    {:noreply, new_state}
  end

  def handle_info(:end_scoring, state) do
    new_state = Map.merge(state, setup_game(state.players))
    # Broadcasting the updated state to the players
    for p <- state.players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end

    {:noreply, new_state}
  end

  def handle_info({:player_bid, player, bid, suit}, state) do
    bid = String.to_integer(bid)

    bid_action =
      if bid == 0 do
        "#{player} passed"
      else
        "#{player} bid #{bid}"
      end

    actions = state.actions ++ [bid_action]

    {highest_bid, _highest_bid_player, _highest_bid_suit} = state.winning_bid

    # If the bid is higher, update stateActions, otherwise leave it unchanged.
    winning_bid =
      if bid > highest_bid do
        {bid, player, suit}
      else
        state.winning_bid
      end

    # Check if 3 bids have been made and highest bid is still 0.
    {winning_bid_value, winning_bid_player, winning_bid_suit} = winning_bid
    bagged = length(actions) == 3 and winning_bid_value == 0

    # Check if 4 bids have been made and set phase to "Discard".
    phase = if length(actions) >= 4, do: "Discard", else: state.phase

    # Move to the next player
    current_player_index = Enum.find_index(state.players, fn p -> p == state.current_player end)
    next_player = Enum.at(state.players, rem(current_player_index + 1, 4))

    {updated_hands, updated_deck} =
      if phase == "Discard" do
        {new_cards, new_deck} = draw_cards(state.deck, 3)
        existing_hand = state.hands[winning_bid_player] || []
        updated_hand = existing_hand ++ new_cards
        {Map.put(state.hands, winning_bid_player, updated_hand), new_deck}
      else
        {state.hands, state.deck}
      end

    winning_bid_action = "#{winning_bid_player} won with #{winning_bid_value} #{winning_bid_suit}"
    actions = if phase == "Discard", do: [winning_bid_action], else: actions
    # Set trump if phase is Discard
    trump = if phase == "Discard", do: String.to_atom(winning_bid_suit), else: state.trump

    new_state = %{
      state
      | actions: actions,
        winning_bid: winning_bid,
        current_player: next_player,
        bagged: bagged,
        phase: phase,
        hands: updated_hands,
        deck: updated_deck,
        trump: trump
    }

    for player <- state.players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player}", {:update_state, new_state})
    end

    {:noreply, new_state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          payload: %{joins: joins, leaves: leaves}
        },
        state
      ) do
    # Extracting player names from joins and leaves
    joined_players = Enum.map(joins, fn {player, _meta} -> player end)
    left_players = Enum.map(leaves, fn {player, _meta} -> player end)

    # Updating the activePlayers list
    updated_active_players =
      state.active_players
      |> Enum.concat(joined_players)
      |> Enum.filter(fn player -> player not in left_players end)

    new_state = %{state | active_players: updated_active_players}

    IO.puts("Updated active players: #{inspect(new_state.active_players)}")

    {:noreply, new_state}
  end

  def handle_info({:confirm_discard, player, selected_cards_invalid}, state) do
    selected_cards = Enum.map(selected_cards_invalid, &convert_to_card_format/1)
    # Get the current hand of the player
    current_hand = Map.get(state.hands, player, [])

    # Filter the hand, keeping only the selected cards
    new_hand = Enum.filter(current_hand, fn card -> card in selected_cards end)

    # Update the hands state by setting the new hand for the player
    updated_hands = Map.put(state.hands, player, new_hand)

    # Add the discarded cards to the discard deck
    discarded_cards = Enum.filter(current_hand, fn card -> card not in selected_cards end)
    updated_discard_deck = state.discardDeck ++ discarded_cards

    updated_discarded_players = [player | state.recieved_discards_from]

    # Create the initial new state with the updated hands and discard deck
    new_state = %{
      state
      | hands: updated_hands,
        discardDeck: updated_discard_deck,
        recieved_discards_from: updated_discarded_players
    }

    # Update the phase if all players have discarded
    new_state =
      if length(updated_discarded_players) == length(state.players) do
        {updated_hands, updated_deck} = deal_additional_cards(new_state, state.players)
        winning_bid_player = new_state.winning_bid |> elem(1)

        %{
          new_state
          | phase: "Playing",
            recieved_discards_from: [],
            hands: updated_hands,
            deck: updated_deck,
            actions: [],
            current_player: winning_bid_player
        }
      else
        new_state
      end

    # Broadcast the updated state to the players
    for p <- state.players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end

    {:noreply, new_state}
  end

  def handle_info({:transition_to_end_bid, winning_player}, state) do
    new_state = %{
      state
      | current_player: winning_player,
        played_cards: [],
        suit_led: nil
    }

    # Broadcast the updated state to the players
    for p <- state.players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end

    {:noreply, new_state}
  end

  def handle_info(:transition_to_scoring, state) do
    new_state = %{
      state
      | phase: "Scoring",
        suit_led: nil,
        trump: nil,
        played_cards: [],
        trick_winning_cards: [],
        legal_moves: %{}
    }

    # Broadcast the updated state to the players
    for p <- state.players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end

    Process.send_after(self(), :end_scoring, 8000)

    {:noreply, new_state}
  end

  def handle_info(:transition_to_final_scoring, state) do
    new_state = %{
      state
      | phase: "Final Scoring",
        legal_moves: %{}
    }

    # Broadcast the updated state to the players
    for p <- state.players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end

    {:noreply, new_state}
  end

  defp convert_to_card_format(card_string) do
    [value, suit] = String.split(card_string, "_")
    Website45sV3.Game.Card.new(String.to_integer(value), String.to_atom(suit))
  end

  defp deal_additional_cards(state, players) do
    Enum.reduce(players, {state.hands, state.deck}, fn player, {hands, deck} ->
      current_hand_count = length(Map.get(hands, player, []))
      cards_needed = 5 - current_hand_count

      if cards_needed > 0 do
        {new_cards, new_deck} = draw_cards(deck, cards_needed)
        current_hand = Map.get(hands, player, [])
        new_hand = current_hand ++ new_cards
        {Map.put(hands, player, new_hand), new_deck}
      else
        {hands, deck}
      end
    end)
  end

  defp history_string(current_score, score_change) do
    if score_change == 0 do
      "#{current_score} 0"
    else
      # I don't even need a negative sign because it is already negative?
      "#{current_score + score_change} #{if score_change > 0, do: "+", else: ""}#{score_change}"
    end
  end

  defp evaluate_cards(state, cards) do
    team1_players = [Enum.at(state.players, 0), Enum.at(state.players, 2)]

    highest_card =
      Enum.max_by(cards, fn %{card: card_a} ->
        Enum.all?(cards, fn %{card: card_b} ->
          card_a == card_b or not Card.less_than(card_a, card_b, state.suit_led, state.trump)
        end)
      end)

    winning_team =
      if highest_card.player in team1_players do
        :team1
      else
        :team2
      end

    # Update the score for the winning team in round_scores
    updated_state =
      Map.update!(state, :round_scores, fn scores ->
        Map.update!(scores, winning_team, fn score -> score + 5 end)
      end)

    {highest_card.player, highest_card, updated_state}
  end

  defp evaluate_played_cards(state) do
    evaluate_cards(state, state.played_cards)
  end

  defp evaluate_trick_winner_cards(state) do
    evaluate_cards(state, state.trick_winning_cards)
  end

  defp calculate_legal_moves(state, played_card) do
    trump = state.trump

    state.players
    |> Enum.reduce(%{}, fn player, acc ->
      hand = Map.get(state.hands, player, [])
      legal_cards = get_legal_moves(hand, played_card, trump)
      Map.put(acc, player, legal_cards)
    end)
  end

  def get_legal_moves(hand, card_led, trump) do
    # Determine the suit led
    suit_led =
      if card_led == %Card{suit: :hearts, value: 1} do
        trump
      else
        card_led.suit
      end

    # Get all of the cards that are of suit led
    legal_cards =
      Enum.filter(hand, fn card ->
        if suit_led == trump do
          cond do
            card.suit == trump -> true
            card.suit == :hearts and card.value == 1 -> true
            true -> false
          end
        else
          cond do
            card.suit == suit_led -> true
            card.suit == trump -> true
            card.suit == :hearts and card.value == 1 -> true
            true -> false
          end
        end
      end)

    # Check if all legal cards are of trump suit and if the suit led is not trump
    if Enum.all?(legal_cards, fn card -> card.suit == trump end) and suit_led != trump do
      hand
    else
      # Check if all legal cards are renegable
      if Enum.all?(legal_cards, &is_renegable?(&1, trump, card_led, suit_led)) do
        hand
      else
        # If no legal cards found, return the entire hand
        case legal_cards do
          [] -> hand
          _ -> legal_cards
        end
      end
    end
  end

  defp is_renegable?(card, trump, card_led, suit_led) do
    renegable_cards = [
      %Card{suit: trump, value: 5},
      %Card{suit: trump, value: 11},
      %Card{suit: :hearts, value: 1}
    ]

    # If it's not less_than the card_led and it's in the renegable_cards list, then it is renegable.
    not Card.less_than(card, card_led, suit_led, trump) and
      Enum.any?(renegable_cards, fn renegable_card ->
        renegable_card.suit == card.suit and renegable_card.value == card.value
      end)
  end

  defp handle_scoring_phase(new_state) do
    IO.inspect(new_state, label: "handle scoring phase state")

    {_winning_player, _highest_card, updated_state_with_scores} =
      evaluate_trick_winner_cards(new_state)

    # highest card is +5
    {bid_amount, bid_player, _bid_suit} = updated_state_with_scores.winning_bid

    bid_team =
      if bid_player in [
           Enum.at(updated_state_with_scores.players, 0),
           Enum.at(updated_state_with_scores.players, 2)
         ] do
        :team1
      else
        :team2
      end

    IO.inspect(bid_team, label: "bid team")

    other_team = if bid_team == :team1, do: :team2, else: :team1

    IO.inspect(updated_state_with_scores.round_scores, label: "round scores")
    # Calculate the change in score for each team
    bid_team_score = Map.get(updated_state_with_scores.round_scores, bid_team)
    bid_team_change = if bid_team_score >= bid_amount, do: bid_team_score, else: -bid_amount

    other_team_score_change = Map.get(updated_state_with_scores.round_scores, other_team)

    IO.inspect(updated_state_with_scores.team_scores, label: "team scores 1")
    # Generate history strings
    bid_team_current_score = Map.get(updated_state_with_scores.team_scores, bid_team)
    IO.inspect(bid_team_current_score, label: "bid team current score")
    IO.inspect(bid_team_change, label: "bid team change")
    bid_team_history_string = history_string(bid_team_current_score, bid_team_change)

    other_team_current_score = Map.get(updated_state_with_scores.team_scores, other_team)
    other_team_history_string = history_string(other_team_current_score, other_team_score_change)

    # Append history strings to respective histories
    team_1_history =
      if bid_team == :team1 do
        updated_state_with_scores.team_1_history ++ [bid_team_history_string]
      else
        updated_state_with_scores.team_1_history ++ [other_team_history_string]
      end

    team_2_history =
      if bid_team == :team2 do
        updated_state_with_scores.team_2_history ++ [bid_team_history_string]
      else
        updated_state_with_scores.team_2_history ++ [other_team_history_string]
      end

    # Update team scores
    updated_team_scores =
      Map.update!(updated_state_with_scores.team_scores, bid_team, fn score ->
        score + bid_team_change
      end)

    updated_team_scores =
      Map.update!(updated_team_scores, other_team, fn score -> score + other_team_score_change end)

    team_1_players =
      Enum.join(
        [
          Enum.at(updated_state_with_scores.players, 0),
          Enum.at(updated_state_with_scores.players, 2)
        ],
        ", "
      )

    team_2_players =
      Enum.join(
        [
          Enum.at(updated_state_with_scores.players, 1),
          Enum.at(updated_state_with_scores.players, 3)
        ],
        ", "
      )

    winning_team =
      cond do
        updated_team_scores[:team1] >= 120 -> :team1
        updated_team_scores[:team2] >= 120 -> :team2
        true -> nil
      end

    actions =
      case winning_team do
        :team1 -> ["#{team_1_players} won the game!"]
        :team2 -> ["#{team_2_players} won the game!"]
        _ -> []
      end

    if winning_team == nil do
      Process.send_after(self(), :transition_to_scoring, 2000)
    else
      Process.send_after(self(), :transition_to_final_scoring, 2000)
    end

    %{
      updated_state_with_scores
      | current_player: nil,
        team_scores: updated_team_scores,
        round_scores: %{team1: 0, team2: 0},
        team_1_history: team_1_history,
        team_2_history: team_2_history,
        actions: actions
    }
  end
end
