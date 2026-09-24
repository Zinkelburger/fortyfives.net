defmodule Website45sV3.Game.GameController do
  @moduledoc """
  GenServer shell around a running 45s game: timers, bot control, PubSub
  broadcasts and persistence. The rules themselves live in
  `Website45sV3.Game.Rules`.

  Every player (human or bot) receives a per-seat view of the game built by
  `player_view/2`: their own hand and legal moves, the number of cards the
  other players hold, and the shared table state. The deck, the discard pile
  and other players' hands never leave this process.

  Bot seats and idle players are played by `Website45sV3.Game.BotPlayer`,
  driven from this process through the same timer bookkeeping as the human
  idle clocks (`ensure_timers/1`).
  """
  use GenServer
  require Logger

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotPlayer
  alias Website45sV3.Game.Card
  alias Website45sV3.Game.Deck
  alias Website45sV3.Game.GameEvents
  alias Website45sV3.Game.GameLog
  alias Website45sV3.Game.GameSupervisor
  alias Website45sV3.Game.Rules
  alias Website45sV3.Repo
  alias Website45sV3Web.Presence

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
    all_bot_timeout: 300_000,
    unattended_timeout: 60_000
  }

  @doc """
  A game timing in milliseconds, honouring the `:game_timings` config.
  """
  def timing(key) do
    :website_45s_v3
    |> Application.get_env(:game_timings, [])
    |> Keyword.get(key, Map.fetch!(@default_timings, key))
  end

  ## Client API

  def start_game(game_name, player_tuples) do
    GameSupervisor.start_game(game_name, player_tuples)
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

  @doc """
  The full internal state. For the lobby and tests; players get
  `get_player_view/2`.
  """
  def get_game_state(pid), do: GenServer.call(pid, :get_game_state)

  @doc """
  The redacted view of the game for one seat. Returns `{:error, :not_seated}`
  if the player is not (or no longer) in the game.
  """
  def get_player_view(pid, player_id), do: GenServer.call(pid, {:get_player_view, player_id})

  @doc """
  Builds the per-seat view broadcast to players: only their own hand and
  legal moves, card counts for everyone, and the shared table state.
  """
  def player_view(state, player_id) do
    %{
      game_name: state.game_name,
      phase: state.phase,
      current_player_id: state.current_player_id,
      dealing_player_id: state.dealing_player_id,
      player_ids: state.player_ids,
      player_map: state.player_map,
      hand: Map.get(state.hands, player_id, []),
      hand_counts: Map.new(state.hands, fn {id, hand} -> {id, length(hand)} end),
      legal_moves: Map.get(state.legal_moves, player_id, []),
      actions: state.actions,
      winning_bid: state.winning_bid,
      bagged: state.bagged,
      suit_led: state.suit_led,
      trump: state.trump,
      played_cards: state.played_cards,
      received_discards_from: state.received_discards_from,
      team_scores: state.team_scores,
      team_1_history: state.team_1_history,
      team_2_history: state.team_2_history,
      auto_playing: auto_playing?(state, player_id),
      abandoned: abandoned?(state, player_id)
    }
  end

  ## Server callbacks

  @impl true
  def init({game_name, player_tuples}) do
    player_ids = Enum.map(player_tuples, fn {_name, id} -> id end)
    player_map = Map.new(player_tuples, fn {name, id} -> {id, name} end)

    cond do
      length(player_ids) != 4 or length(Enum.uniq(player_ids)) != 4 ->
        {:stop, {:invalid_players, player_ids}}

      match?({:error, _}, Registry.register(Website45sV3.Registry, game_name, [])) ->
        {:stop, {:already_registered, game_name}}

      true ->
        # A supervisor shutdown (deploy, restart) must still reach
        # terminate/2, so the game's log is written instead of lost.
        Process.flag(:trap_exit, true)

        state =
          player_ids
          |> setup_game(player_map, Enum.random(player_ids))
          |> Map.merge(%{
            team_scores: %{team1: 0, team2: 0},
            team_1_history: [],
            team_2_history: [],
            # :team1 | :team2 once the game is decided (see score_hand/1).
            winning_team: nil,
            game_name: game_name
          })
          |> Map.merge(GameEvents.init())
          |> log_deal()

        Phoenix.PubSub.subscribe(Website45sV3.PubSub, game_name)
        # Register before any player is redirected, so the lobby can always
        # answer "which game is this user in?". Cleaned up by ActiveGames'
        # monitor when this process exits.
        ActiveGames.register_game(self(), game_name, player_ids)

        state
        |> schedule_termination_timer(timing(:game_max_lifetime))
        |> ensure_timers()
        |> reconcile_all_bot_controlled_timer()
        |> reconcile_unattended_timer()
        |> then(&{:ok, &1})
    end
  end

  # `player_ids` keeps the queue join order: players seated 1st and 3rd play
  # against players seated 2nd and 4th.
  defp setup_game(player_ids, player_map, previous_dealer_id) do
    deck = Deck.new() |> Deck.shuffle()
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
      discard_pile: [],
      actions: [],
      winning_bid: {0, nil, nil},
      bids_placed: 0,
      active_players: [],
      received_discards_from: [],
      bagged: false,
      suit_led: nil,
      trump: nil,
      played_cards: [],
      trick_winning_cards: [],
      round_scores: %{team1: 0, team2: 0},
      turn_timer: nil,
      discard_timers: %{},
      termination_timer_ref: nil,
      seat_bots: MapSet.new(seat_bot_ids),
      auto_play_players: MapSet.new(),
      abandoned_players: MapSet.new(),
      all_bot_controlled_timer_ref: nil,
      unattended_timer: nil
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
    Enum.reduce(1..num_cards//1, {[], deck}, fn _, {hand, deck} ->
      {card, deck} = Deck.remove_card(deck)
      {[card | hand], deck}
    end)
  end

  ## Player control (bots, auto-play, abandonment)

  defp seat_bot?(state, player_id), do: MapSet.member?(state.seat_bots, player_id)

  defp auto_playing?(state, player_id), do: MapSet.member?(state.auto_play_players, player_id)

  defp abandoned?(state, player_id), do: MapSet.member?(state.abandoned_players, player_id)

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

  # Nobody plays a game out for an empty table: bots only stand in for
  # people who are still around. Once every human has abandoned their seat
  # the game ends straight away; once none is connected, it ends after
  # `:unattended_timeout`, long enough for a reload or a phone switching
  # apps. Games seated entirely by bots are left to the all-bot timeout.
  defp human_seats(state), do: Enum.reject(state.player_ids, &seat_bot?(state, &1))

  defp deserted?(state) do
    humans = human_seats(state)
    humans != [] and Enum.all?(humans, &abandoned?(state, &1))
  end

  defp unattended?(state) do
    humans = human_seats(state)

    humans != [] and
      not Enum.any?(humans, &(&1 in state.active_players and not abandoned?(state, &1)))
  end

  # The timer record is `{ref, token}`; the token lets the handler ignore a
  # message from a timer that was cancelled after it had already fired.
  defp reconcile_unattended_timer(state) do
    case {unattended?(state), state.unattended_timer} do
      {true, nil} ->
        token = make_ref()

        ref =
          Process.send_after(self(), {:unattended_timeout, token}, timing(:unattended_timeout))

        %{state | unattended_timer: {ref, token}}

      {false, {ref, _token}} ->
        Process.cancel_timer(ref)
        %{state | unattended_timer: nil}

      _ ->
        state
    end
  end

  defp cancel_all_bot_controlled_timer(state) do
    if state.all_bot_controlled_timer_ref,
      do: Process.cancel_timer(state.all_bot_controlled_timer_ref)

    %{state | all_bot_controlled_timer_ref: nil}
  end

  defp enable_auto_play(state, player_id) do
    if bot_controlled?(state, player_id) do
      state
    else
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", :auto_playing)

      state
      |> Map.update!(:auto_play_players, &MapSet.put(&1, player_id))
      |> log("idle", %{p: GameEvents.seat(state, player_id), phase: state.phase})
      |> reconcile_all_bot_controlled_timer()
    end
  end

  defp disable_auto_play(state, player_id) do
    if auto_playing?(state, player_id) do
      Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{player_id}", :auto_play_disabled)

      state
      |> Map.update!(:auto_play_players, &MapSet.delete(&1, player_id))
      |> log("resume", %{p: GameEvents.seat(state, player_id)})
      |> reconcile_all_bot_controlled_timer()
    else
      state
    end
  end

  # A human who acts for themselves takes back control from the idle bot.
  defp resume_manual_control(state, _player_id, true = _from_bot), do: state
  defp resume_manual_control(state, player_id, false), do: disable_auto_play(state, player_id)

  ## Timer management
  #
  # Timers are reconciled, not restarted: `ensure_timers/1` compares what is
  # running against what the phase needs and only starts or cancels timers
  # where they differ, so presence changes or repeated events never reset a
  # player's clock. A timer record is `%{kind: :idle | :bot, ref: ref}`
  # plus, for the turn timer, the `player_id` and `phase` it was armed for.

  defp ensure_timers(%{phase: "Discard"} = state) do
    state |> cancel_turn_timer() |> ensure_discard_timers()
  end

  defp ensure_timers(state) do
    state |> cancel_discard_timers() |> ensure_turn_timer()
  end

  defp ensure_turn_timer(%{current_player_id: nil} = state), do: cancel_turn_timer(state)

  defp ensure_turn_timer(%{current_player_id: player_id, phase: phase} = state) do
    kind = control_kind(state, player_id)

    case state.turn_timer do
      %{player_id: ^player_id, phase: ^phase, kind: ^kind} ->
        state

      _ ->
        state = cancel_turn_timer(state)
        ref = start_turn_timer(kind, player_id, phase)
        %{state | turn_timer: %{player_id: player_id, phase: phase, kind: kind, ref: ref}}
    end
  end

  defp start_turn_timer(:bot, player_id, phase) do
    Process.send_after(self(), {:bot_execute, player_id, phase}, timing(:bot_move_delay))
  end

  defp start_turn_timer(:idle, player_id, phase) do
    Process.send_after(self(), {:idle_timeout, player_id, phase}, timing(:idle_timeout))
  end

  defp cancel_turn_timer(%{turn_timer: nil} = state), do: state

  defp cancel_turn_timer(%{turn_timer: %{ref: ref}} = state) do
    Process.cancel_timer(ref)
    %{state | turn_timer: nil}
  end

  defp ensure_discard_timers(state) do
    pending = state.player_ids -- state.received_discards_from

    kept =
      Enum.reduce(state.discard_timers, %{}, fn {player_id, timer}, acc ->
        if player_id in pending and timer.kind == control_kind(state, player_id) do
          Map.put(acc, player_id, timer)
        else
          Process.cancel_timer(timer.ref)
          acc
        end
      end)

    timers =
      Enum.reduce(pending, kept, fn player_id, acc ->
        Map.put_new_lazy(acc, player_id, fn -> start_discard_timer(state, player_id) end)
      end)

    %{state | discard_timers: timers}
  end

  defp start_discard_timer(state, player_id) do
    case control_kind(state, player_id) do
      :bot ->
        ref =
          Process.send_after(
            self(),
            {:bot_execute, player_id, "Discard"},
            timing(:bot_move_delay)
          )

        %{kind: :bot, ref: ref}

      :idle ->
        ref =
          Process.send_after(self(), {:discard_idle_timeout, player_id}, timing(:discard_timeout))

        %{kind: :idle, ref: ref}
    end
  end

  defp cancel_discard_timers(state) do
    Enum.each(state.discard_timers, fn {_player_id, timer} -> Process.cancel_timer(timer.ref) end)
    %{state | discard_timers: %{}}
  end

  # Drops the record of a timer that has just fired (its message was
  # consumed) without cancelling anything. Only the record of the timer that
  # produced the message is dropped: a stale message from a timer that was
  # since replaced must not orphan the replacement.
  defp clear_fired_turn_timer(
         %{turn_timer: %{player_id: player_id, kind: kind}} = state,
         player_id,
         kind
       ),
       do: %{state | turn_timer: nil}

  defp clear_fired_turn_timer(state, _player_id, _kind), do: state

  defp clear_fired_discard_timer(state, player_id, kind) do
    case state.discard_timers do
      %{^player_id => %{kind: ^kind}} ->
        %{state | discard_timers: Map.delete(state.discard_timers, player_id)}

      _ ->
        state
    end
  end

  defp control_kind(state, player_id) do
    if bot_controlled?(state, player_id), do: :bot, else: :idle
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

  @impl true
  def handle_call(:get_game_state, _from, state), do: {:reply, state, state}

  def handle_call({:get_player_view, player_id}, _from, state) do
    if player_id in state.player_ids and not abandoned?(state, player_id) do
      {:reply, {:ok, player_view(state, player_id)}, state}
    else
      {:reply, {:error, :not_seated}, state}
    end
  end

  ## Termination

  defp handle_game_end(state, termination_reason) do
    state =
      state
      |> cancel_turn_timer()
      |> cancel_discard_timers()
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

      attrs =
        state
        |> log("end", %{r: end_reason_label(termination_reason)})
        |> GameEvents.finalize(termination_reason)
        |> Map.put(:player_usernames, player_usernames)

      %GameLog{}
      |> GameLog.changeset(attrs)
      |> Repo.insert()
    end

    Logger.info("GameController terminated with reason: #{inspect(termination_reason)}")
    :ok
  end

  defp end_reason_label(:normal), do: "normal"
  defp end_reason_label({:error, reason}), do: "crash: " <> inspect(reason)

  ## Event log (see GameEvents)

  defp log(state, type, attrs), do: GameEvents.log(state, type, attrs)

  defp log_deal(state) do
    log(state, "deal", %{
      hand: length(state.team_1_history) + 1,
      dealer: GameEvents.seat(state, state.dealing_player_id),
      hands: GameEvents.hands(state)
    })
  end

  # A single catch-all so that unexpected crash reasons (exceptions, kills
  # with reason tuples, ...) still notify players instead of leaving them on
  # a frozen game screen.
  @impl true
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
  #
  # Every message goes through here so the timers are reconciled exactly
  # once per state change (see "Timer management"); the handlers themselves
  # never think about clocks.

  @impl true
  def handle_info(msg, state) do
    case handle_message(msg, state) do
      {:noreply, new_state} ->
        if deserted?(new_state),
          do: {:stop, :normal, new_state},
          else: {:noreply, new_state |> ensure_timers() |> reconcile_unattended_timer()}

      other ->
        other
    end
  end

  defp handle_message(:terminate_game, state) do
    {:stop, :normal, state}
  end

  defp handle_message(:all_bot_controlled_timeout, state) do
    if all_bot_controlled?(state) do
      {:stop, :normal, state}
    else
      {:noreply, %{state | all_bot_controlled_timer_ref: nil}}
    end
  end

  defp handle_message({:unattended_timeout, token}, %{unattended_timer: {_ref, token}} = state) do
    {:stop, :normal, state}
  end

  defp handle_message({:unattended_timeout, _stale_token}, state), do: {:noreply, state}

  defp handle_message(
         {:idle_timeout, player_id, phase},
         %{current_player_id: player_id, phase: phase} = state
       ) do
    new_state =
      state
      |> clear_fired_turn_timer(player_id, :idle)
      |> enable_auto_play(player_id)

    {:noreply, new_state}
  end

  defp handle_message({:idle_timeout, _player_id, _phase}, state), do: {:noreply, state}

  defp handle_message({:discard_idle_timeout, player_id}, %{phase: "Discard"} = state) do
    new_state =
      state
      |> clear_fired_discard_timer(player_id, :idle)
      |> then(fn state ->
        if player_id in state.received_discards_from,
          do: state,
          else: enable_auto_play(state, player_id)
      end)

    {:noreply, new_state}
  end

  defp handle_message({:discard_idle_timeout, _player_id}, state), do: {:noreply, state}

  defp handle_message({:bot_execute, player_id, "Bidding"}, %{phase: "Bidding"} = state) do
    state = clear_fired_turn_timer(state, player_id, :bot)

    if bot_controlled?(state, player_id) and state.current_player_id == player_id do
      {bid, suit} = BotPlayer.pick_bid(state, player_id)
      maybe_player_bid(player_id, Integer.to_string(bid), suit, state, true)
    else
      {:noreply, state}
    end
  end

  defp handle_message({:bot_execute, player_id, "Discard"}, %{phase: "Discard"} = state) do
    state = clear_fired_discard_timer(state, player_id, :bot)

    if bot_controlled?(state, player_id) and player_id not in state.received_discards_from do
      cards = BotPlayer.pick_discard(state, player_id)
      maybe_confirm_discard(player_id, cards, state, true)
    else
      {:noreply, state}
    end
  end

  defp handle_message({:bot_execute, player_id, "Playing"}, %{phase: "Playing"} = state) do
    state = clear_fired_turn_timer(state, player_id, :bot)

    if bot_controlled?(state, player_id) and state.current_player_id == player_id do
      card = BotPlayer.pick_card(state, player_id)
      maybe_play_card(player_id, card, state, true)
    else
      {:noreply, state}
    end
  end

  defp handle_message({:bot_execute, _player_id, _phase}, state), do: {:noreply, state}

  defp handle_message({:play_card, player_id, card}, state),
    do: maybe_play_card(player_id, card, state, false)

  defp handle_message({:play_card, player_id, card, :bot}, state),
    do: maybe_play_card(player_id, card, state, true)

  defp handle_message({:player_bid, player_id, bid, suit}, state),
    do: maybe_player_bid(player_id, bid, suit, state, false)

  defp handle_message({:player_bid, player_id, bid, suit, :bot}, state),
    do: maybe_player_bid(player_id, bid, suit, state, true)

  defp handle_message({:confirm_discard, player, selected_cards}, state),
    do: maybe_confirm_discard(player, selected_cards, state, false)

  defp handle_message({:confirm_discard, player, selected_cards, :bot}, state),
    do: maybe_confirm_discard(player, selected_cards, state, true)

  defp handle_message(:end_scoring, state) do
    # Cancel outstanding timers before the merge below overwrites their refs,
    # otherwise the old 2h termination timer keeps running and kills the game
    # mid-play.
    state =
      state
      |> cancel_turn_timer()
      |> cancel_discard_timers()
      |> cancel_termination_timer()

    new_state =
      state
      |> Map.merge(setup_game(state.player_ids, state.player_map, state.dealing_player_id))
      |> Map.put(:active_players, state.active_players)
      |> Map.put(:seat_bots, state.seat_bots)
      |> Map.put(:auto_play_players, state.auto_play_players)
      |> Map.put(:abandoned_players, state.abandoned_players)
      |> Map.put(:all_bot_controlled_timer_ref, state.all_bot_controlled_timer_ref)
      |> Map.put(:unattended_timer, state.unattended_timer)
      |> log_deal()

    broadcast_state(new_state)

    new_state =
      new_state
      |> schedule_termination_timer(timing(:game_max_lifetime))

    {:noreply, new_state}
  end

  defp handle_message(
         %Phoenix.Socket.Broadcast{
           event: "presence_diff"
         },
         state
       ) do
    # A diff describes connections, not seats: one tab leaving must not
    # disconnect a player whose other tab is still watching the table.
    present = Presence.list(state.game_name)
    updated_active_players = Enum.filter(state.player_ids, &Map.has_key?(present, &1))
    joined_players = updated_active_players -- state.active_players
    left_players = state.active_players -- updated_active_players

    state =
      Enum.reduce(left_players, state, fn player, acc ->
        if player in acc.player_ids,
          do: log(acc, "leave", %{p: GameEvents.seat(acc, player)}),
          else: acc
      end)

    state =
      Enum.reduce(joined_players, state, fn player, acc ->
        if player in acc.player_ids,
          do: log(acc, "join", %{p: GameEvents.seat(acc, player)}),
          else: acc
      end)

    new_state =
      joined_players
      |> Enum.reduce(%{state | active_players: updated_active_players}, fn player, acc ->
        # Abandoned seats stay bot-controlled even if the player somehow
        # shows up in presence again.
        if abandoned?(acc, player), do: acc, else: disable_auto_play(acc, player)
      end)

    {:noreply, new_state}
  end

  # A player permanently gives up their seat: their session is freed for new
  # games and a bot plays out the rest of this one. Unlike idle auto-play,
  # this is not reversible — an abandoned player can no longer rejoin.
  defp handle_message({:abandon_game, player_id}, state) do
    if player_id in state.player_ids and not seat_bot?(state, player_id) and
         not abandoned?(state, player_id) do
      ActiveGames.remove_player(player_id)

      # Take over the seat without enable_auto_play/2's :auto_playing
      # broadcast — that message ("a bot is playing for you") is for players
      # who idled out, not ones who deliberately left. The timer
      # reconciliation in handle_info/2 then nudges the bot right away if
      # the game is waiting on this seat.
      new_state =
        state
        |> Map.update!(:abandoned_players, &MapSet.put(&1, player_id))
        |> Map.update!(:auto_play_players, &MapSet.put(&1, player_id))
        |> log("abandon", %{p: GameEvents.seat(state, player_id), phase: state.phase})
        |> reconcile_all_bot_controlled_timer()

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp handle_message({:resume_control, player_id}, state) do
    if auto_playing?(state, player_id) and not abandoned?(state, player_id) do
      {:noreply, disable_auto_play(state, player_id)}
    else
      {:noreply, state}
    end
  end

  defp handle_message({:transition_to_end_bid, winning_player_id}, %{phase: "Playing"} = state) do
    new_state = %{
      state
      | current_player_id: winning_player_id,
        played_cards: [],
        suit_led: nil
    }

    broadcast_state(new_state)

    {:noreply, new_state}
  end

  defp handle_message({:transition_to_end_bid, _winning_player_id}, state), do: {:noreply, state}

  defp handle_message(:transition_to_scoring, state) do
    new_state = %{
      state
      | phase: "Scoring",
        current_player_id: nil,
        suit_led: nil,
        trump: nil,
        played_cards: [],
        trick_winning_cards: [],
        legal_moves: %{}
    }

    broadcast_state(new_state)

    Process.send_after(self(), :end_scoring, timing(:scoring_display))
    # Nobody is on the clock while scores are shown.
    {:noreply, new_state}
  end

  defp handle_message(:transition_to_final_scoring, state) do
    new_state = %{
      state
      | phase: "Final Scoring",
        current_player_id: nil,
        legal_moves: %{}
    }

    broadcast_state(new_state)

    {:noreply, schedule_termination_timer(new_state, timing(:final_scoring_timeout))}
  end

  defp handle_message(_msg, state), do: {:noreply, state}

  defp broadcast_state(state) do
    for player <- state.active_players, player in state.player_ids do
      Phoenix.PubSub.broadcast(
        Website45sV3.PubSub,
        "user:#{player}",
        {:update_state, player_view(state, player)}
      )
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
    new_state =
      state
      |> resume_manual_control(player_id, from_bot)
      |> log("play", %{p: GameEvents.seat(state, player_id), c: Card.encode(card), b: from_bot})
      |> place_card(player_id, card)
      |> maybe_complete_trick()
      |> maybe_complete_hand()

    broadcast_state(new_state)

    {:noreply, new_state}
  end

  defp place_card(state, player_id, card) do
    leading? = state.played_cards == []

    %{
      state
      | hands: Map.update!(state.hands, player_id, &List.delete(&1, card)),
        played_cards: [%{player_id: player_id, card: card} | state.played_cards],
        suit_led: if(leading?, do: Rules.suit_led(card, state.trump), else: state.suit_led),
        legal_moves:
          if(leading?, do: calculate_legal_moves(state, card), else: state.legal_moves),
        current_player_id: next_player(state.player_ids, player_id)
    }
  end

  defp maybe_complete_trick(%{played_cards: played} = state) when length(played) < 4, do: state

  defp maybe_complete_trick(state) do
    winner = Rules.trick_winner(state.played_cards, state.suit_led, state.trump)
    tricks_won = [winner | state.trick_winning_cards]
    trick_number = length(tricks_won)

    # The winner leads the next trick once everyone has seen this one. After
    # the fifth trick the hand is scored instead, so no lead follows.
    if trick_number < 5 do
      Process.send_after(
        self(),
        {:transition_to_end_bid, winner.player_id},
        timing(:trick_transition)
      )
    end

    state
    |> add_round_points(winner.player_id, 5)
    |> log("trick", %{
      n: trick_number,
      w: GameEvents.seat(state, winner.player_id),
      c: Card.encode(winner.card)
    })
    |> Map.merge(%{
      current_player_id: nil,
      trick_winning_cards: tricks_won,
      legal_moves: %{},
      actions:
        state.actions ++ ["#{state.player_map[winner.player_id]} won trick #{trick_number}"]
    })
  end

  defp maybe_complete_hand(%{trick_winning_cards: tricks} = state) when length(tricks) < 5,
    do: state

  defp maybe_complete_hand(state), do: score_hand(state)

  defp add_round_points(state, player_id, points) do
    team = Rules.team_for(state.player_ids, player_id)
    update_in(state.round_scores[team], &(&1 + points))
  end

  defp calculate_legal_moves(state, played_card) do
    Map.new(state.player_ids, fn player ->
      hand = Map.get(state.hands, player, [])
      {player, Rules.legal_moves(hand, played_card, state.trump)}
    end)
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
    dealer? = player_id == state.dealing_player_id

    with {:ok, bid_value, bid_suit} <- Rules.parse_bid(bid, suit),
         true <- Rules.valid_bid?(bid_value, bid_suit, highest_bid, state.bagged, dealer?) do
      handle_player_bid(player_id, bid_value, bid_suit, state, from_bot)
    else
      _ -> {:noreply, state}
    end
  end

  defp maybe_player_bid(_player_id, _bid, _suit, state, _from_bot),
    do: {:noreply, state}

  defp handle_player_bid(player_id, bid, suit, state, from_bot) do
    new_state =
      state
      |> resume_manual_control(player_id, from_bot)
      |> log("bid", %{p: GameEvents.seat(state, player_id), v: bid, s: suit, b: from_bot})
      |> record_bid(player_id, bid, suit)
      |> maybe_bag_dealer()
      |> maybe_start_discard()

    broadcast_state(new_state)

    {:noreply, new_state}
  end

  defp record_bid(state, player_id, bid, suit) do
    name = state.player_map[player_id]
    {highest_bid, _player, _suit} = state.winning_bid
    dealer? = player_id == state.dealing_player_id

    {action, winning_bid} =
      cond do
        bid == 0 ->
          {"#{name} passed", state.winning_bid}

        Rules.hold?(bid, highest_bid, dealer?) ->
          {"#{name} held at #{bid}", {bid, player_id, suit}}

        true ->
          {"#{name} bid #{bid}", {bid, player_id, suit}}
      end

    %{
      state
      | actions: state.actions ++ [action],
        winning_bid: winning_bid,
        bids_placed: state.bids_placed + 1,
        current_player_id: next_player(state.player_ids, player_id)
    }
  end

  # Three passes leave the dealer bagged: they must bid.
  defp maybe_bag_dealer(%{bids_placed: 3, winning_bid: {0, _, _}} = state),
    do: %{state | bagged: true}

  defp maybe_bag_dealer(state), do: state

  # Once all four have bid, the winner takes the kitty and names trump.
  defp maybe_start_discard(%{bids_placed: 4} = state) do
    {bid, winner, suit} = state.winning_bid
    {kitty, deck} = draw_cards(state.deck, 3)

    state =
      log(state, "kitty", %{
        p: GameEvents.seat(state, winner),
        v: bid,
        s: suit,
        c: GameEvents.cards(kitty)
      })

    %{
      state
      | phase: "Discard",
        trump: suit,
        deck: deck,
        hands: Map.update!(state.hands, winner, &(&1 ++ kitty)),
        actions: ["#{state.player_map[winner]} won with #{bid} #{suit}"]
    }
  end

  defp maybe_start_discard(state), do: state

  ## Discarding

  defp maybe_confirm_discard(player, selected_cards, %{phase: "Discard"} = state, from_bot) do
    hand = Map.get(state.hands, player, [])

    case Rules.validate_discard(selected_cards, hand) do
      {:ok, kept_cards} -> do_confirm_discard(player, kept_cards, state, from_bot)
      :error -> {:noreply, state}
    end
  end

  defp maybe_confirm_discard(_player, _selected_cards, state, _from_bot),
    do: {:noreply, state}

  defp do_confirm_discard(player, kept_cards, state, from_bot) do
    new_state =
      state
      |> resume_manual_control(player, from_bot)
      |> log("discard", %{
        p: GameEvents.seat(state, player),
        keep: GameEvents.cards(kept_cards),
        b: from_bot
      })
      |> keep_cards(player, kept_cards)
      |> maybe_start_playing()

    broadcast_state(new_state)

    {:noreply, new_state}
  end

  defp keep_cards(state, player, kept_cards) do
    current_hand = Map.get(state.hands, player, [])
    {kept, discarded} = Enum.split_with(current_hand, &(&1 in kept_cards))

    %{
      state
      | hands: Map.put(state.hands, player, kept),
        discard_pile: state.discard_pile ++ discarded,
        received_discards_from: Enum.uniq([player | state.received_discards_from])
    }
  end

  # Once everyone has discarded, hands are refilled and the bidder leads.
  defp maybe_start_playing(state) do
    if length(state.received_discards_from) == length(state.player_ids) do
      {hands, deck} = deal_additional_cards(state, state.player_ids)
      {_bid, winning_bid_player_id, _suit} = state.winning_bid

      state = %{
        state
        | phase: "Playing",
          received_discards_from: [],
          hands: hands,
          deck: deck,
          actions: [],
          current_player_id: winning_bid_player_id
      }

      log(state, "play_start", %{hands: GameEvents.hands(state)})
    else
      state
    end
  end

  defp deal_additional_cards(state, player_ids) do
    Enum.reduce(player_ids, {state.hands, state.deck}, fn player, {hands, deck} ->
      current_hand = Map.get(hands, player, [])
      cards_needed = 5 - length(current_hand)
      {new_cards, deck} = draw_cards(deck, cards_needed)
      {Map.put(hands, player, current_hand ++ new_cards), deck}
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

  # The highest trump played in the hand earns its team a 5 point bonus.
  # Only trumps qualify, whatever suit was led in the trick that won it.
  defp award_best_trump(state) do
    case Rules.best_trump(state.trick_winning_cards, state.trump) do
      nil -> state
      %{player_id: player_id} -> add_round_points(state, player_id, 5)
    end
  end

  defp score_hand(new_state) do
    state = award_best_trump(new_state)

    result =
      Rules.score_round(
        state.round_scores,
        state.team_scores,
        state.winning_bid,
        state.player_ids
      )

    transition =
      if result.winning_team == nil,
        do: :transition_to_scoring,
        else: :transition_to_final_scoring

    Process.send_after(self(), transition, timing(:trick_transition))

    state =
      log(state, "score", %{
        hand: length(state.team_1_history) + 1,
        d1: result.changes.team1,
        d2: result.changes.team2,
        t1: result.team_scores.team1,
        t2: result.team_scores.team2,
        win: result.winning_team
      })

    %{
      state
      | current_player_id: nil,
        team_scores: result.team_scores,
        round_scores: %{team1: 0, team2: 0},
        team_1_history:
          state.team_1_history ++
            [history_string(state.team_scores.team1, result.changes.team1)],
        team_2_history:
          state.team_2_history ++
            [history_string(state.team_scores.team2, result.changes.team2)],
        winning_team: result.winning_team,
        actions: game_over_actions(state, result.winning_team)
    }
  end

  defp game_over_actions(_state, nil), do: []

  defp game_over_actions(state, winning_team) do
    seats = if winning_team == :team1, do: [0, 2], else: [1, 3]

    names =
      Enum.map_join(seats, ", ", fn i -> state.player_map[Enum.at(state.player_ids, i)] end)

    ["#{names} won the game!"]
  end
end
