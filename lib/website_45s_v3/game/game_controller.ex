defmodule Website45sV3.Game.GameController do
  @moduledoc """
  GenServer shell around a running 45s game: timers, bot control, PubSub
  broadcasts and persistence. The rules themselves live in
  `Website45sV3.Game.Rules`.
  """
  use GenServer
  require Logger

  alias Website45sV3.Game.Card
  alias Website45sV3.Game.Deck
  alias Website45sV3.Game.GameLog
  alias Website45sV3.Game.Rules
  alias Website45sV3.Repo

  # Delays and timeouts (milliseconds). Overridable through the
  # :game_timings application env so tests can run a full game quickly.
  @default_timings %{
    idle_timeout: 30_000,
    discard_timeout: 30_000,
    bot_move_delay: 1_000,
    trick_transition: 2_000,
    scoring_display: 6_000,
    final_scoring_timeout: 60_000,
    game_max_lifetime: 7_200_000,
    all_bot_timeout: 300_000
  }

  defp timing(key) do
    :website_45s_v3
    |> Application.get_env(:game_timings, [])
    |> Keyword.get(key, Map.fetch!(@default_timings, key))
  end

  ## Client API

  def start_game(game_name, player_tuples) do
    Website45sV3.Game.GameSupervisor.start_game(game_name, player_tuples)
  end

  def start_link({game_name, player_tuples}) do
    GenServer.start_link(__MODULE__, {game_name, player_tuples})
  end

  def child_spec({game_name, _player_tuples} = arg) do
    %{
      id: {__MODULE__, game_name},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary
    }
  end

  def dispatch(game_name, message) do
    case Registry.lookup(Website45sV3.Registry, game_name) do
      [{game_pid, _}] ->
        send(game_pid, message)
        :ok

      [] ->
        {:error, :game_not_found}
    end
  end

  def get_game_state(pid), do: GenServer.call(pid, :get_game_state)

  ## Server callbacks

  def init({game_name, player_tuples}) do
    player_ids = Enum.map(player_tuples, fn {_name, id} -> id end)
    player_map = Map.new(player_tuples, fn {name, id} -> {id, name} end)

    cond do
      length(player_ids) != 4 or length(Enum.uniq(player_ids)) != 4 ->
        {:stop, {:invalid_players, player_ids}}

      match?({:error, _}, Registry.register(Website45sV3.Registry, game_name, [])) ->
        {:stop, {:already_registered, game_name}}

      true ->
        state =
          setup_game(player_ids, player_map, Enum.random(player_ids))
          |> Map.put(:team_scores, %{team1: 0, team2: 0})
          |> Map.put(:team_1_history, [])
          |> Map.put(:team_2_history, [])
          |> Map.put(:game_name, game_name)

        Phoenix.PubSub.subscribe(Website45sV3.PubSub, game_name)

        state
        |> schedule_termination_timer(timing(:game_max_lifetime))
        |> schedule_idle_timer()
        |> reconcile_all_bot_controlled_timer()
        |> then(&{:ok, &1})
    end
  end

  # `player_ids` keeps the queue join order: players seated 1st and 3rd play
  # against players seated 2nd and 4th.
  defp setup_game(player_ids, player_map, previous_dealer_id) do
    deck = Deck.new() |> Deck.shuffle(5)
    {hands, deck} = deal_cards(player_ids, deck, 5)

    new_dealer_id = next_player(player_ids, previous_dealer_id)
    starting_player_id = next_player(player_ids, new_dealer_id)

    seat_bot_ids = Enum.filter(player_ids, &String.starts_with?(&1, "bot_"))

    %{
      phase: "Bidding",
      current_player_id: starting_player_id,
      dealing_player_id: new_dealer_id,
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
      discard_timer_refs: %{},
      termination_timer_ref: nil,
      seat_bots: MapSet.new(seat_bot_ids),
      auto_play_players: MapSet.new(),
      all_bot_controlled_timer_ref: nil
    }
  end

  defp next_player(player_ids, player_id) do
    index = Enum.find_index(player_ids, &(&1 == player_id)) || 0
    Enum.at(player_ids, rem(index + 1, length(player_ids)))
  end

  defp deal_cards(player_ids, deck, num_cards) do
    Enum.reduce(player_ids, {Map.new(), deck}, fn player_id, {hands, deck} ->
      {hand, deck} = draw_cards(deck, num_cards)
      {Map.put(hands, player_id, hand), deck}
    end)
  end

  defp draw_cards(deck, num_cards) do
    Enum.reduce(1..num_cards, {[], deck}, fn _, {hand, deck} ->
      {card, deck} = Deck.remove_card(deck)
      {[card | hand], deck}
    end)
  end

  ## Timer management

  defp cancel_idle_timers(state) do
    if state.idle_timer_ref, do: Process.cancel_timer(state.idle_timer_ref)

    Enum.each(state.discard_timer_refs || %{}, fn {_player, ref} ->
      Process.cancel_timer(ref)
    end)

    %{state | idle_timer_ref: nil, discard_timer_refs: %{}}
  end

  defp cancel_all_bot_controlled_timer(state) do
    if state.all_bot_controlled_timer_ref,
      do: Process.cancel_timer(state.all_bot_controlled_timer_ref)

    %{state | all_bot_controlled_timer_ref: nil}
  end

  defp cancel_termination_timer(state) do
    if state.termination_timer_ref, do: Process.cancel_timer(state.termination_timer_ref)
    %{state | termination_timer_ref: nil}
  end

  defp schedule_termination_timer(state, timeout_ms) do
    state = cancel_termination_timer(state)
    ref = Process.send_after(self(), :terminate_game, timeout_ms)
    %{state | termination_timer_ref: ref}
  end

  defp seat_bot?(state, player_id), do: MapSet.member?(state.seat_bots, player_id)

  defp auto_playing?(state, player_id), do: MapSet.member?(state.auto_play_players, player_id)

  defp bot_controlled?(state, player_id),
    do: seat_bot?(state, player_id) or auto_playing?(state, player_id)

  defp all_bot_controlled?(state) do
    Enum.all?(state.player_ids, &bot_controlled?(state, &1))
  end

  defp reconcile_all_bot_controlled_timer(state) do
    cond do
      all_bot_controlled?(state) and is_nil(state.all_bot_controlled_timer_ref) ->
        ref = Process.send_after(self(), :all_bot_controlled_timeout, timing(:all_bot_timeout))
        %{state | all_bot_controlled_timer_ref: ref}

      not all_bot_controlled?(state) and state.all_bot_controlled_timer_ref != nil ->
        Process.cancel_timer(state.all_bot_controlled_timer_ref)
        %{state | all_bot_controlled_timer_ref: nil}

      true ->
        state
    end
  end

  defp enable_auto_play(state, player_id) do
    cond do
      seat_bot?(state, player_id) ->
        state

      auto_playing?(state, player_id) ->
        state

      true ->
        Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", :auto_playing)

        state
        |> Map.update!(:auto_play_players, &MapSet.put(&1, player_id))
        |> reconcile_all_bot_controlled_timer()
    end
  end

  defp disable_auto_play(state, player_id) do
    if auto_playing?(state, player_id) do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", :auto_play_disabled)

      state
      |> Map.update!(:auto_play_players, &MapSet.delete(&1, player_id))
      |> reconcile_all_bot_controlled_timer()
    else
      state
    end
  end

  defp resume_manual_control(state, _player_id, true), do: state

  defp resume_manual_control(state, player_id, false) do
    disable_auto_play(state, player_id)
  end

  defp schedule_discard_timers(state) do
    refs =
      Enum.reduce(state.player_ids, %{}, fn player_id, acc ->
        ref =
          Process.send_after(self(), {:discard_idle_timeout, player_id}, timing(:discard_timeout))

        Map.put(acc, player_id, ref)
      end)

    Enum.each(state.player_ids, fn player_id ->
      if player_id not in state.received_discards_from and
           bot_controlled?(state, player_id) do
        Process.send_after(self(), {:bot_execute, player_id, "Discard"}, timing(:bot_move_delay))
      end
    end)

    %{state | discard_timer_refs: refs}
  end

  defp schedule_player_timer(state, player_id) do
    if bot_controlled?(state, player_id) do
      Process.send_after(self(), {:bot_execute, player_id, state.phase}, timing(:bot_move_delay))
      %{state | idle_timer_ref: nil}
    else
      ref =
        Process.send_after(
          self(),
          {:idle_timeout, player_id, state.phase},
          timing(:idle_timeout)
        )

      %{state | idle_timer_ref: ref}
    end
  end

  defp schedule_idle_timer(state) do
    state = cancel_idle_timers(state)

    cond do
      state.phase == "Discard" ->
        schedule_discard_timers(state)

      state.current_player_id ->
        schedule_player_timer(state, state.current_player_id)

      true ->
        state
    end
  end

  def handle_call(:get_game_state, _from, state), do: {:reply, state, state}

  ## Termination

  defp handle_game_end(state, termination_reason) do
    state =
      state
      |> cancel_idle_timers()
      |> cancel_all_bot_controlled_timer()
      |> cancel_termination_timer()

    message =
      case termination_reason do
        :normal -> :game_end
        {:error, reason} -> {:game_crash, reason}
      end

    # Notify all players about the game termination
    for player_id <- state.player_ids do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", message)
    end

    players_are_all_bots? = MapSet.size(state.seat_bots) == length(state.player_ids)

    unless players_are_all_bots? do
      player_usernames =
        Enum.map(state.player_ids, fn id ->
          Map.get(state.player_map, id, "Anonymous")
        end)

      %GameLog{}
      |> GameLog.changeset(%{player_usernames: player_usernames})
      |> Repo.insert()
    end

    Logger.info("GameController terminated with reason: #{inspect(termination_reason)}")
    :ok
  end

  # A single catch-all so that unexpected crash reasons (exceptions, kills
  # with reason tuples, ...) still notify players instead of leaving them on
  # a frozen game screen.
  def terminate(reason, state) when reason in [:normal, :shutdown] do
    handle_game_end(state, :normal)
  end

  def terminate({:shutdown, _}, state) do
    handle_game_end(state, :normal)
  end

  def terminate({:error, reason}, state) do
    handle_game_end(state, {:error, reason})
  end

  def terminate(reason, state) do
    Logger.error("GameController crashed with reason: #{inspect(reason)}")
    handle_game_end(state, {:error, reason})
  end

  ## Message handlers

  def handle_info(:terminate_game, state) do
    {:stop, :normal, state}
  end

  def handle_info(:all_bot_controlled_timeout, state) do
    if all_bot_controlled?(state) do
      {:stop, :normal, state}
    else
      {:noreply, %{state | all_bot_controlled_timer_ref: nil}}
    end
  end

  def handle_info({:terminate_error, reason}, state) do
    Logger.error(
      "Terminating GameController with reason: #{inspect(reason)} and state: #{inspect(state)}"
    )

    {:stop, {:error, reason}, state}
  end

  def handle_info(
        {:idle_timeout, player_id, phase},
        %{current_player_id: player_id, phase: phase} = state
      ) do
    new_state =
      state
      |> enable_auto_play(player_id)
      |> Map.put(:idle_timer_ref, nil)

    send(self(), {:bot_execute, player_id, phase})

    {:noreply, new_state}
  end

  def handle_info({:idle_timeout, _player_id, _phase}, state), do: {:noreply, state}

  def handle_info({:discard_idle_timeout, player_id}, %{phase: "Discard"} = state) do
    if player_id in state.received_discards_from do
      new_refs = Map.delete(state.discard_timer_refs, player_id)
      {:noreply, %{state | discard_timer_refs: new_refs}}
    else
      send(self(), {:bot_execute, player_id, "Discard"})

      new_state =
        state
        |> enable_auto_play(player_id)
        |> then(fn updated_state ->
          %{
            updated_state
            | discard_timer_refs: Map.delete(updated_state.discard_timer_refs, player_id)
          }
        end)

      {:noreply, new_state}
    end
  end

  def handle_info({:discard_idle_timeout, _player_id}, state), do: {:noreply, state}

  def handle_info({:bot_execute, player_id, "Bidding"}, %{phase: "Bidding"} = state) do
    if bot_controlled?(state, player_id) do
      {bid, suit} = Website45sV3.Game.BotPlayer.pick_bid(state, player_id)
      send(self(), {:player_bid, player_id, Integer.to_string(bid), suit, :bot})
    end

    {:noreply, state}
  end

  def handle_info({:bot_execute, player_id, "Discard"}, %{phase: "Discard"} = state) do
    if bot_controlled?(state, player_id) do
      cards = Website45sV3.Game.BotPlayer.pick_discard(state, player_id)
      send(self(), {:confirm_discard, player_id, cards, :bot})
    end

    {:noreply, state}
  end

  def handle_info({:bot_execute, player_id, "Playing"}, %{phase: "Playing"} = state) do
    if bot_controlled?(state, player_id) do
      card = Website45sV3.Game.BotPlayer.pick_card(state, player_id)
      send(self(), {:play_card, player_id, card, :bot})
    end

    {:noreply, state}
  end

  def handle_info({:play_card, player_id, card}, state),
    do: maybe_play_card(player_id, card, state, false)

  def handle_info({:play_card, player_id, card, :bot}, state),
    do: maybe_play_card(player_id, card, state, true)

  def handle_info({:player_bid, player_id, bid, suit}, state),
    do: maybe_player_bid(player_id, bid, suit, state, false)

  def handle_info({:player_bid, player_id, bid, suit, :bot}, state),
    do: maybe_player_bid(player_id, bid, suit, state, true)

  def handle_info({:confirm_discard, player, selected_cards}, state),
    do: maybe_confirm_discard(player, selected_cards, state, false)

  def handle_info({:confirm_discard, player, selected_cards, :bot}, state),
    do: maybe_confirm_discard(player, selected_cards, state, true)

  def handle_info(:end_scoring, state) do
    # Cancel outstanding timers before the merge below overwrites their refs,
    # otherwise the old 2h termination timer keeps running and kills the game
    # mid-play.
    state =
      state
      |> cancel_idle_timers()
      |> cancel_termination_timer()

    new_state =
      state
      |> Map.merge(setup_game(state.player_ids, state.player_map, state.dealing_player_id))
      |> Map.put(:active_players, state.active_players)
      |> Map.put(:seat_bots, state.seat_bots)
      |> Map.put(:auto_play_players, state.auto_play_players)
      |> Map.put(:all_bot_controlled_timer_ref, state.all_bot_controlled_timer_ref)

    broadcast_state(new_state)

    new_state = schedule_termination_timer(new_state, timing(:game_max_lifetime))
    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          payload: %{joins: joins, leaves: leaves}
        },
        state
      ) do
    joined_players = Enum.map(joins, fn {player, _meta} -> player end)
    left_players = Enum.map(leaves, fn {player, _meta} -> player end)

    updated_active_players =
      state.active_players
      |> Enum.concat(joined_players)
      |> Enum.uniq()
      |> Enum.filter(fn player -> player not in left_players end)

    new_state =
      joined_players
      |> Enum.reduce(%{state | active_players: updated_active_players}, fn player, acc ->
        disable_auto_play(acc, player)
      end)

    new_state = schedule_idle_timer(new_state)

    {:noreply, new_state}
  end

  def handle_info({:resume_control, player_id}, state) do
    if auto_playing?(state, player_id) do
      new_state =
        state
        |> disable_auto_play(player_id)
        |> schedule_idle_timer()

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:transition_to_end_bid, winning_player_id}, state) do
    new_state = %{
      state
      | current_player_id: winning_player_id,
        played_cards: [],
        suit_led: nil
    }

    broadcast_state(new_state)

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

    broadcast_state(new_state)

    Process.send_after(self(), :end_scoring, timing(:scoring_display))
    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  def handle_info(:transition_to_final_scoring, state) do
    new_state = %{
      state
      | phase: "Final Scoring",
        legal_moves: %{}
    }

    broadcast_state(new_state)

    new_state = schedule_termination_timer(new_state, timing(:final_scoring_timeout))
    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast_state(state) do
    for player <- state.active_players do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player}", {:update_state, state})
    end
  end

  ## Playing a card

  defp maybe_play_card(
         player_id,
         %Card{} = card,
         %{phase: "Playing", current_player_id: player_id} = state,
         from_bot
       ) do
    current_hand = Map.get(state.hands, player_id, [])
    legal = Map.get(state.legal_moves, player_id, current_hand)

    if card in legal and card in current_hand do
      handle_play_card(player_id, card, state, from_bot)
    else
      {:noreply, state}
    end
  end

  defp maybe_play_card(_player_id, _card, state, _from_bot), do: {:noreply, state}

  defp handle_play_card(player_id, card, state, from_bot) do
    state = resume_manual_control(state, player_id, from_bot)

    current_hand = Map.get(state.hands, player_id, [])
    new_hand = List.delete(current_hand, card)
    updated_hands = Map.put(state.hands, player_id, new_hand)

    played_cards_entry = %{player_id: player_id, card: card}
    updated_played_cards = [played_cards_entry | state.played_cards || []]

    legal_moves =
      if Enum.empty?(state.played_cards),
        do: calculate_legal_moves(state, card),
        else: state.legal_moves

    suit_led = if Enum.empty?(state.played_cards), do: card.suit, else: state.suit_led

    new_state = %{
      state
      | hands: updated_hands,
        played_cards: updated_played_cards,
        suit_led: suit_led,
        current_player_id: next_player(state.player_ids, state.current_player_id),
        legal_moves: legal_moves
    }

    new_state =
      if length(updated_played_cards) >= 4 do
        {winning_player_id, highest_card, updated_state_with_scores} =
          award_trick(new_state, new_state.played_cards)

        if length(state.trick_winning_cards) < 5 do
          Process.send_after(
            self(),
            {:transition_to_end_bid, winning_player_id},
            timing(:trick_transition)
          )
        end

        %{
          updated_state_with_scores
          | current_player_id: nil,
            actions:
              updated_state_with_scores.actions ++
                [
                  "#{state.player_map[winning_player_id]} won trick #{length(state.trick_winning_cards) + 1}"
                ],
            trick_winning_cards: [
              %{player_id: winning_player_id, card: highest_card.card}
              | state.trick_winning_cards || []
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

    broadcast_state(new_state)

    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  ## Bidding

  defp maybe_player_bid(
         player_id,
         bid,
         suit,
         %{phase: "Bidding", current_player_id: player_id} = state,
         from_bot
       ) do
    {highest_bid, _player, _suit} = state.winning_bid

    with {:ok, bid_value, bid_suit} <- Rules.parse_bid(bid, suit),
         true <- Rules.valid_bid?(bid_value, bid_suit, highest_bid, state.bagged) do
      handle_player_bid(player_id, bid_value, bid_suit, state, from_bot)
    else
      _ -> {:noreply, state}
    end
  end

  defp maybe_player_bid(_player_id, _bid, _suit, state, _from_bot), do: {:noreply, state}

  defp handle_player_bid(player_id, bid, suit, state, from_bot) do
    state = resume_manual_control(state, player_id, from_bot)

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

    next_player_id = next_player(state.player_ids, state.current_player_id)

    {updated_hands, updated_deck} =
      if phase == "Discard" do
        {new_cards, new_deck} = draw_cards(state.deck, 3)
        existing_hand = state.hands[winning_bid_player] || []
        updated_hand = existing_hand ++ new_cards
        {Map.put(state.hands, winning_bid_player, updated_hand), new_deck}
      else
        {state.hands, state.deck}
      end

    winning_bid_action =
      "#{state.player_map[winning_bid_player]} won with #{winning_bid_value} #{winning_bid_suit}"

    actions = if phase == "Discard", do: [winning_bid_action], else: actions
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

    broadcast_state(new_state)

    new_state = schedule_idle_timer(new_state)
    {:noreply, new_state}
  end

  ## Discarding

  defp maybe_confirm_discard(player, selected_cards, %{phase: "Discard"} = state, from_bot) do
    hand = Map.get(state.hands, player, [])

    case Rules.validate_discard(selected_cards, hand) do
      {:ok, kept_cards} -> do_confirm_discard(player, kept_cards, state, from_bot)
      :error -> {:noreply, state}
    end
  end

  defp maybe_confirm_discard(_player, _selected_cards, state, _from_bot), do: {:noreply, state}

  defp do_confirm_discard(player, kept_cards, state, from_bot) do
    state = resume_manual_control(state, player, from_bot)

    # cancel any pending discard timer for this player
    {ref, refs} = Map.pop(state.discard_timer_refs, player)
    if ref, do: Process.cancel_timer(ref)
    state = %{state | discard_timer_refs: refs}

    current_hand = Map.get(state.hands, player, [])
    new_hand = Enum.filter(current_hand, fn card -> card in kept_cards end)
    updated_hands = Map.put(state.hands, player, new_hand)

    discarded_cards = Enum.filter(current_hand, fn card -> card not in kept_cards end)
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

    broadcast_state(new_state)

    new_state =
      if new_state.phase == "Discard" do
        new_state
      else
        schedule_idle_timer(new_state)
      end

    {:noreply, new_state}
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

  ## Scoring

  defp history_string(current_score, score_change) do
    if score_change == 0 do
      "#{current_score} 0"
    else
      "#{current_score + score_change} #{if score_change > 0, do: "+", else: ""}#{score_change}"
    end
  end

  defp award_trick(state, entries) do
    winner = Rules.trick_winner(entries, state.suit_led, state.trump)
    winning_team = Rules.team_for(state.player_ids, winner.player_id)

    updated_state =
      Map.update!(state, :round_scores, fn scores ->
        Map.update!(scores, winning_team, fn score -> score + 5 end)
      end)

    {winner.player_id, winner, updated_state}
  end

  defp calculate_legal_moves(state, played_card) do
    trump = state.trump

    state.player_ids
    |> Enum.reduce(%{}, fn player, acc ->
      hand = Map.get(state.hands, player, [])
      legal_cards = Rules.legal_moves(hand, played_card, trump)
      Map.put(acc, player, legal_cards)
    end)
  end

  defp handle_scoring_phase(new_state) do
    # The best of the five trick-winning cards earns its team a 5 point bonus.
    {_winning_player_id, _highest_card, state} =
      award_trick(new_state, new_state.trick_winning_cards)

    result =
      Rules.score_round(
        state.round_scores,
        state.team_scores,
        state.winning_bid,
        state.player_ids
      )

    team_1_history =
      state.team_1_history ++
        [history_string(state.team_scores.team1, result.changes.team1)]

    team_2_history =
      state.team_2_history ++
        [history_string(state.team_scores.team2, result.changes.team2)]

    team_players = fn indexes ->
      indexes
      |> Enum.map(fn i -> state.player_map[Enum.at(state.player_ids, i)] end)
      |> Enum.join(", ")
    end

    actions =
      case result.winning_team do
        :team1 -> ["#{team_players.([0, 2])} won the game!"]
        :team2 -> ["#{team_players.([1, 3])} won the game!"]
        nil -> []
      end

    if result.winning_team == nil do
      Process.send_after(self(), :transition_to_scoring, timing(:trick_transition))
    else
      Process.send_after(self(), :transition_to_final_scoring, timing(:trick_transition))
    end

    %{
      state
      | current_player_id: nil,
        team_scores: result.team_scores,
        round_scores: %{team1: 0, team2: 0},
        team_1_history: team_1_history,
        team_2_history: team_2_history,
        actions: actions
    }
  end
end
