defmodule Website45sV3.Game.GameController do
  use GenServer
  alias Deck
  alias Suit
  alias Website45sV3.Game.Card
  alias Website45sV3.Game.GameLog
  alias Website45sV3.Repo

  def start_game(game_name, player_tuples) do
    GenServer.start_link(__MODULE__, {game_name, player_tuples})
  end

  def init({game_name, player_tuples}) do
    player_map = Map.new(player_tuples, fn {player_name, player_id} -> {player_id, player_name} end)

    case Registry.register(Website45sV3.Registry, game_name, []) do
      {:ok, _pid} ->
        state =
          setup_game(player_map, Enum.random(Map.keys(player_map)))
          |> Map.put(:team_scores, %{team1: 0, team2: 0})
          |> Map.put(:team_1_history, [])
          |> Map.put(:team_2_history, [])
          |> Map.put(:game_name, game_name)
          |> Map.put(:player_map, player_map)
          |> schedule_idle_timer()

        Phoenix.PubSub.subscribe(Website45sV3.PubSub, game_name)
        # Schedule termination after 2 hours
        Process.send_after(self(), :terminate_game, 7200000)
        {:ok, state}

      {:error, {:already_registered, _pid}} ->
        {:stop, {:already_registered, game_name}}
    end
  end

  defp setup_game(player_map, previous_dealer_id) do
    player_ids = Map.keys(player_map)
    deck = Deck.new() |> Deck.shuffle(5)
    {hands, deck} = deal_cards(player_ids, deck, 5)

    new_dealer_id =
      case previous_dealer_id do
        nil ->
          Enum.random(player_ids)

        dealer_id ->
          current_dealer_index = Enum.find_index(player_ids, fn id -> id == dealer_id end)
          Enum.at(player_ids, rem(current_dealer_index + 1, length(player_ids)))
      end

    current_dealer_index = Enum.find_index(player_ids, fn id -> id == new_dealer_id end)
    starting_player_id = Enum.at(player_ids, rem(current_dealer_index + 1, length(player_ids)))

    %{
      phase: "Bidding",
      current_player_id: starting_player_id,
      dealing_player_id: starting_player_id,
      player_ids: player_ids,
      player_map: player_map,
      hands: hands,
      legal_moves: %{},
      deck: deck,
      discardDeck: [],
      actions: [],
      winning_bid: {0, nil, nil},
      active_players: [],
      received_discards_from: [],
      bagged: false,
      suit_led: nil,
      trump: nil,
      played_cards: [],
      trick_winning_cards: [],
      round_scores: %{team1: 0, team2: 0},
      idle_timer_ref: nil,
      bot_players: MapSet.new()
    }
  end

  defp deal_cards(player_ids, deck, num_cards) when is_list(player_ids) do
    Enum.reduce(player_ids, {Map.new(), deck}, fn player_id, {hands, deck} ->
      {hand, deck} = draw_cards(deck, num_cards)
      {Map.put(hands, player_id, hand), deck}
    end)
  end

  defp deal_cards(player_id, deck, num_cards) when is_binary(player_id) do
    {hand, new_deck} = draw_cards(deck, num_cards)
    {%{player_id => hand}, new_deck}
  end

  defp draw_cards(deck, num_cards) do
    Enum.reduce(1..num_cards, {[], deck}, fn _, {hand, deck} ->
      {card, deck} = Deck.remove_card(deck)
      {[card | hand], deck}
    end)
  end

  defp schedule_idle_timer(state) do
    if state.idle_timer_ref do
      Process.cancel_timer(state.idle_timer_ref)
    end

    if state.current_player_id do
      ref = Process.send_after(self(), {:idle_timeout, state.current_player_id, state.phase}, 60_000)
      %{state | idle_timer_ref: ref}
    else
      %{state | idle_timer_ref: nil}
    end
  end

  def handle_call(:get_game_state, _from, state), do: {:reply, state, state}

  def get_game_state(pid), do: GenServer.call(pid, :get_game_state)

  defp handle_game_end(state, termination_reason) do
    message =
      case termination_reason do
        :normal -> :game_end
        {:error, reason} -> {:game_crash, reason}
      end

    # Notify all players about the game termination
    for player_id <- state.player_ids do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", message)
    end

    player_usernames =
      Enum.map(state.player_ids, fn id ->
        Map.get(state.player_map, id, "Anonymous")
      end)

    %GameLog{}
    |> GameLog.changeset(%{player_usernames: player_usernames})
    |> Repo.insert()

    IO.puts("GameController terminated with reason: #{inspect(termination_reason)}")
    :ok
  end

  def terminate(:normal, state) do
    handle_game_end(state, :normal)
  end

  def terminate({:error, reason}, state) do
    handle_game_end(state, {:error, reason})
  end

  def handle_info(:terminate_game, state) do
    {:stop, :normal, state}
  end

  def handle_info({:terminate_error, reason}, state) do
    IO.puts("Terminating GameController with reason: #{inspect(reason)} and state: #{inspect(state)}")
    {:stop, {:error, reason}, state}
  end

  def handle_info({:idle_timeout, player_id, phase}, state) do
    new_state = %{state | bot_players: MapSet.put(state.bot_players, player_id), idle_timer_ref: nil}
    Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", :auto_playing)
    Process.send_after(self(), {:bot_execute, player_id, phase}, 5_000)
    {:noreply, new_state}
  end

  def handle_info({:bot_execute, player_id, "Bidding"}, state) do
    {bid, suit} = Website45sV3.Game.BotPlayer.pick_bid(state, player_id)
    send(self(), {:player_bid, player_id, Integer.to_string(bid), suit, :bot})
    {:noreply, state}
  end

  def handle_info({:bot_execute, player_id, "Discard"}, state) do
    cards = Website45sV3.Game.BotPlayer.pick_discard(state, player_id)
    send(self(), {:confirm_discard, player_id, cards, :bot})
    {:noreply, state}
  end

  def handle_info({:bot_execute, player_id, "Playing"}, state) do
    card = Website45sV3.Game.BotPlayer.pick_card(state, player_id)
    send(self(), {:play_card, player_id, card, :bot})
    {:noreply, state}
  end

  def handle_info({:play_card, player_id, card}, %{phase: "Playing", current_player_id: player_id} = state) do
    current_hand = Map.get(state.hands, player_id, [])
    legal = Map.get(state.legal_moves, player_id, current_hand)

    if card in legal and card in current_hand do
      handle_play_card(player_id, card, state, false)
    else
      {:noreply, state}
    end
  end

  def handle_info({:play_card, _player_id, _card}, state), do: {:noreply, state}

  def handle_info({:play_card, player_id, card, :bot}, %{phase: "Playing", current_player_id: player_id} = state) do
    current_hand = Map.get(state.hands, player_id, [])
    legal = Map.get(state.legal_moves, player_id, current_hand)

    if card in legal and card in current_hand do
      handle_play_card(player_id, card, state, true)
    else
      {:noreply, state}
    end
  end

  def handle_info({:play_card, _player_id, _card, :bot}, state), do: {:noreply, state}


  def handle_info(:end_scoring, state) do
    new_state = Map.merge(state, setup_game(state.player_map, state.dealing_player_id))
    # Broadcasting the updated state to the players
    for p <- state.player_ids do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end
    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  def handle_info({:player_bid, player_id, bid, suit}, %{phase: "Bidding", current_player_id: player_id} = state) do
    if valid_bid?(bid, suit, state) do
      handle_player_bid(player_id, bid, suit, state, false)
    else
      {:noreply, state}
    end
  end

  def handle_info({:player_bid, _player_id, _bid, _suit}, state), do: {:noreply, state}

  def handle_info({:player_bid, player_id, bid, suit, :bot}, %{phase: "Bidding", current_player_id: player_id} = state) do
    if valid_bid?(bid, suit, state) do
      handle_player_bid(player_id, bid, suit, state, true)
    else
      {:noreply, state}
    end
  end

  def handle_info({:player_bid, _player_id, _bid, _suit, :bot}, state), do: {:noreply, state}


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

  def handle_info({:confirm_discard, player, selected_cards_invalid}, %{phase: "Discard"} = state) do
    if valid_discard?(player, selected_cards_invalid, state) do
      do_confirm_discard(player, selected_cards_invalid, state, false)
    else
      {:noreply, state}
    end
  end

  def handle_info({:confirm_discard, _player, _selected_cards_invalid}, state), do: {:noreply, state}

  def handle_info({:confirm_discard, player, selected_cards_invalid, :bot}, %{phase: "Discard"} = state) do
    if valid_discard?(player, selected_cards_invalid, state) do
      do_confirm_discard(player, selected_cards_invalid, state, true)
    else
      {:noreply, state}
    end
  end

  def handle_info({:confirm_discard, _player, _cards, :bot}, state), do: {:noreply, state}


  def handle_info({:transition_to_end_bid, winning_player_id}, state) do
    new_state = %{
      state
      | current_player_id: winning_player_id,
        played_cards: [],
        suit_led: nil
    }

    # Broadcast the updated state to the players
    for p <- state.player_ids do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end
    new_state = schedule_idle_timer(new_state)
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
    for p <- state.player_ids do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end

    Process.send_after(self(), :end_scoring, 6000)
    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  def handle_info(:transition_to_final_scoring, state) do
    new_state = %{
      state
      | phase: "Final Scoring",
        legal_moves: %{}
    }

    # Broadcast the updated state to the players
    for p <- state.player_ids do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
    end

    # terminate process after 1 minute
    Process.send_after(self(), :terminate_game, 60_000)
    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_play_card(player_id, card, state, from_bot) do
    state =
      if MapSet.member?(state.bot_players, player_id) and not from_bot do
        Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", :auto_play_disabled)
        %{state | bot_players: MapSet.delete(state.bot_players, player_id)}
      else
        state
      end
    if state.idle_timer_ref, do: Process.cancel_timer(state.idle_timer_ref)

    card = if is_binary(card.suit), do: %{card | suit: String.to_atom(card.suit)}, else: card

    current_hand = Map.get(state.hands, player_id, [])
    new_hand = List.delete(current_hand, card)
    updated_hands = Map.put(state.hands, player_id, new_hand)

    played_cards_entry = %{player_id: player_id, card: card}
    updated_played_cards = [played_cards_entry | state.played_cards || []]

    legal_moves = if Enum.empty?(state.played_cards), do: calculate_legal_moves(state, card), else: state.legal_moves

    suit_led = if Enum.empty?(state.played_cards), do: card.suit, else: state.suit_led

    current_player_index = Enum.find_index(state.player_ids, fn id -> id == state.current_player_id end)
    next_player_id = Enum.at(state.player_ids, rem(current_player_index + 1, length(state.player_ids)))

    new_state = %{
      state
      | hands: updated_hands,
        played_cards: updated_played_cards,
        suit_led: suit_led,
        current_player_id: next_player_id,
        legal_moves: legal_moves
    }

    new_state =
      if length(updated_played_cards) >= 4 do
        {winning_player_id, highest_card, updated_state_with_scores} =
          evaluate_played_cards(new_state)

        if length(state.trick_winning_cards) < 5 do
          Process.send_after(self(), {:transition_to_end_bid, winning_player_id}, 2000)
        end

        %{
          updated_state_with_scores
          | current_player_id: nil,
            actions:
              updated_state_with_scores.actions ++
                ["#{state.player_map[winning_player_id]} won trick #{length(state.trick_winning_cards) + 1}"],
            trick_winning_cards: [
              %{player_id: winning_player_id, card: highest_card.card} | state.trick_winning_cards || []
            ],
            legal_moves: %{}
        }
      else
        new_state
      end

    new_state =
      if length(new_state.trick_winning_cards) >= 5 do
        handle_scoring_phase(new_state)
      else
        new_state
      end

    for p_id <- state.player_ids do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p_id}", {:update_state, new_state})
    end
    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  defp handle_player_bid(player_id, bid, suit, state, from_bot) do
    state =
      if MapSet.member?(state.bot_players, player_id) and not from_bot do
        Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", :auto_play_disabled)
        %{state | bot_players: MapSet.delete(state.bot_players, player_id)}
      else
        state
      end
    if state.idle_timer_ref, do: Process.cancel_timer(state.idle_timer_ref)

    bid = String.to_integer(bid)

    bid_action =
      if bid == 0 do
        "#{state.player_map[player_id]} passed"
      else
        "#{state.player_map[player_id]} bid #{bid}"
      end

    actions = state.actions ++ [bid_action]

    {highest_bid, _highest_bid_player, _highest_bid_suit} = state.winning_bid

    winning_bid =
      if bid > highest_bid do
        {bid, player_id, suit}
      else
        state.winning_bid
      end

    {winning_bid_value, winning_bid_player, winning_bid_suit} = winning_bid
    bagged = length(actions) == 3 and winning_bid_value == 0

    phase = if length(actions) >= 4, do: "Discard", else: state.phase

    current_player_index = Enum.find_index(state.player_ids, fn p -> p == state.current_player_id end)
    next_player_id = Enum.at(state.player_ids, rem(current_player_index + 1, 4))

    {updated_hands, updated_deck} =
      if phase == "Discard" do
        {new_cards, new_deck} = draw_cards(state.deck, 3)
        existing_hand = state.hands[winning_bid_player] || []
        updated_hand = existing_hand ++ new_cards
        {Map.put(state.hands, winning_bid_player, updated_hand), new_deck}
      else
        {state.hands, state.deck}
      end

    winning_bid_action = "#{state.player_map[winning_bid_player]} won with #{winning_bid_value} #{winning_bid_suit}"
    actions = if phase == "Discard", do: [winning_bid_action], else: actions
    # Set trump if phase is Discard
    trump = if phase == "Discard", do: winning_bid_suit, else: state.trump

    new_state = %{
      state
      | actions: actions,
        winning_bid: winning_bid,
        current_player_id: next_player_id,
        bagged: bagged,
        phase: phase,
        hands: updated_hands,
        deck: updated_deck,
        trump: trump
    }

    for player <- state.player_ids do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player}", {:update_state, new_state})
    end
    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  defp valid_bid?(bid, suit, state) do
    suit_string = if is_atom(suit), do: Atom.to_string(suit), else: suit

    base_valid =
      bid in ["0", "15", "20", "25", "30"] and
        ((bid == "0" and suit_string == "pass") or
           (bid != "0" and suit_string in ["hearts", "diamonds", "clubs", "spades"]))

    if state.bagged do
      base_valid and bid != "0"
    else
      base_valid
    end
  end

  defp valid_discard?(player, selected_card_strings, state) do
    hand = Map.get(state.hands, player, [])
    # convert string identifiers into Card structs
    cards = Enum.map(selected_card_strings, &convert_to_card_format/1)

    # must keep between 1 and 5 cards, and all kept cards must actually be in hand
    length(cards) in 1..5 and Enum.all?(cards, &(&1 in hand))
  end

  defp do_confirm_discard(player, selected_cards_invalid, state, from_bot) do
    unless valid_discard?(player, selected_cards_invalid, state) do
      {:noreply, state}
    else
      state =
        if MapSet.member?(state.bot_players, player) and not from_bot do
          Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player}", :auto_play_disabled)
          %{state | bot_players: MapSet.delete(state.bot_players, player)}
        else
          state
        end

      if state.idle_timer_ref, do: Process.cancel_timer(state.idle_timer_ref)

      selected_cards = Enum.map(selected_cards_invalid, &convert_to_card_format/1)
      current_hand = Map.get(state.hands, player, [])
      new_hand = Enum.filter(current_hand, fn card -> card in selected_cards end)
      updated_hands = Map.put(state.hands, player, new_hand)

      discarded_cards = Enum.filter(current_hand, fn card -> card not in selected_cards end)
      updated_discard_deck = state.discardDeck ++ discarded_cards

      updated_discarded_players = Enum.uniq([player | state.received_discards_from])

      new_state = %{
        state
        | hands: updated_hands,
          discardDeck: updated_discard_deck,
          received_discards_from: updated_discarded_players
      }

      new_state =
        if length(updated_discarded_players) == length(state.player_ids) do
          {updated_hands, updated_deck} = deal_additional_cards(new_state, state.player_ids)
          winning_bid_player_id = new_state.winning_bid |> elem(1)

          %{
            new_state
            | phase: "Playing",
              received_discards_from: [],
              hands: updated_hands,
              deck: updated_deck,
              actions: [],
              current_player_id: winning_bid_player_id
          }
        else
          new_state
        end

      for p <- state.player_ids do
        Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{p}", {:update_state, new_state})
      end

      new_state = schedule_idle_timer(new_state)
      {:noreply, new_state}
    end
  end

  defp convert_to_card_format(card_string) do
    [value, suit] = String.split(card_string, "_")
    Website45sV3.Game.Card.new(String.to_integer(value), String.to_existing_atom(suit))
  end

  defp deal_additional_cards(state, player_ids) do
    Enum.reduce(player_ids, {state.hands, state.deck}, fn player, {hands, deck} ->
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
    team1_players = [Enum.at(state.player_ids, 0), Enum.at(state.player_ids, 2)]

    highest_card =
      Enum.max_by(cards, fn %{card: card_a} ->
        Enum.all?(cards, fn %{card: card_b} ->
          card_a == card_b or not Card.less_than(card_a, card_b, state.suit_led, state.trump)
        end)
      end)

    winning_team =
      if highest_card.player_id in team1_players do
        :team1
      else
        :team2
      end

    # Update the score for the winning team in round_scores
    updated_state =
      Map.update!(state, :round_scores, fn scores ->
        Map.update!(scores, winning_team, fn score -> score + 5 end)
      end)

    {highest_card.player_id, highest_card, updated_state}
  end

  defp evaluate_played_cards(state) do
    evaluate_cards(state, state.played_cards)
  end

  defp evaluate_trick_winner_cards(state) do
    evaluate_cards(state, state.trick_winning_cards)
  end

  defp calculate_legal_moves(state, played_card) do
    trump = state.trump

    state.player_ids
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
    {_winning_player_id, _highest_card, updated_state_with_scores} =
      evaluate_trick_winner_cards(new_state)

    # highest card is +5
    {bid_amount, bid_player, _bid_suit} = updated_state_with_scores.winning_bid

    bid_team =
      if bid_player in [
           Enum.at(updated_state_with_scores.player_ids, 0),
           Enum.at(updated_state_with_scores.player_ids, 2)
         ] do
        :team1
      else
        :team2
      end

    other_team = if bid_team == :team1, do: :team2, else: :team1

    # Calculate the change in score for each team
    bid_team_score = Map.get(updated_state_with_scores.round_scores, bid_team)
    bid_team_change = if bid_team_score >= bid_amount, do: bid_team_score, else: -bid_amount

    other_team_score_change = Map.get(updated_state_with_scores.round_scores, other_team)

    # Generate history strings
    bid_team_current_score = Map.get(updated_state_with_scores.team_scores, bid_team)
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
      [
        updated_state_with_scores.player_map[Enum.at(updated_state_with_scores.player_ids, 0)],
        updated_state_with_scores.player_map[Enum.at(updated_state_with_scores.player_ids, 2)]
      ]
      |> Enum.join(", ")

    team_2_players =
      [
        updated_state_with_scores.player_map[Enum.at(updated_state_with_scores.player_ids, 1)],
        updated_state_with_scores.player_map[Enum.at(updated_state_with_scores.player_ids, 3)]
      ]
      |> Enum.join(", ")

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
      | current_player_id: nil,
        team_scores: updated_team_scores,
        round_scores: %{team1: 0, team2: 0},
        team_1_history: team_1_history,
        team_2_history: team_2_history,
        actions: actions
    }
  end
end
