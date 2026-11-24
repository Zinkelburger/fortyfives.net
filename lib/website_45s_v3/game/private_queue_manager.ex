defmodule Website45sV3.Game.PrivateQueueManager do
  @moduledoc """
  Private lobbies: invite-only queues identified by a UUID in a share link.
  A lobby starts its game when four players are seated and is swept when it
  expires or sits empty for too long.

  As in the public queue, the process that adds a player holds their seat
  (see `QueueHolders`): once every tab holding it has released it, the player
  leaves the lobby.

  Unlike the public queue, a seat outlives a lost connection. Sending the
  link means leaving the browser for another app, and a phone drops the
  page's socket within seconds of that; so does every switch back to the
  chat while friends arrive. A player whose last page lost its connection is
  kept seated as *away* for `@away_grace_ms` and takes the seat back by
  opening the lobby again (`seated?/2`, then `add_player/4`). Leaving, or a
  live navigation to another lobby page, still frees the seat at once. A tab
  closed, or sent to a page outside the lobby's live session, closes its
  socket the same way a lost connection does, so that seat is kept too.
  """
  use GenServer
  require Logger

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.Matchmaking
  alias Website45sV3.Game.QueueHolders
  alias Website45sV3.Security.RateLimiter
  alias Website45sV3Web.Presence

  # How long an unfilled private lobby lives before it is cleaned up.
  @queue_ttl_ms 2 * 60 * 60 * 1000
  # A lobby nobody is sitting in is reaped much sooner, so abandoned links do
  # not hold seats against `max_queues`. Long enough to survive a refresh, a
  # reconnect, or a player leaving and rejoining.
  @empty_queue_ttl_ms 15 * 60 * 1000
  @sweep_interval_ms 5 * 60 * 1000
  # How long a seat is kept for a player whose page lost its connection.
  @away_grace_ms 3 * 60 * 1000
  # Minimum seconds between two lobby creations by the same user. Only there
  # to absorb a double tap: a group whose game fell apart makes a new table
  # straight away, and the network limit bounds everything else.
  @create_cooldown_s 15
  @default_max_queues 100
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  # Client API
  def start_link(_args) do
    GenServer.start_link(
      __MODULE__,
      %{queues: %{}, last_created: %{}, holders: QueueHolders.new(), away: %{}},
      name: __MODULE__
    )
  end

  @doc """
  Creates a lobby. `seat: name` seats the owner in it under that name, as
  away until their lobby page arrives and takes the seat.
  """
  def create_queue(id, owner_id, remote_ip \\ nil, opts \\ []) do
    GenServer.call(__MODULE__, {:create_queue, id, owner_id, remote_ip, opts})
  end

  @doc """
  Opens the lobby a finished private game offers its players for another
  game, unless one of them already has. The id comes from the game, not the
  client, so the creation cooldown and network limit do not apply.
  """
  def reopen_queue(id, owner_id) do
    GenServer.call(__MODULE__, {:reopen_queue, id, owner_id})
  end

  @doc """
  Seats a player in a lobby, held by the calling process. Options:
  `on_drop:` — run if the player is dropped because every process holding
  them exited (see `QueueHolders`).
  """
  def add_player(id, {name, user_id}, remote_ip \\ nil, opts \\ []) do
    GenServer.call(__MODULE__, {:add_player, id, {name, user_id}, remote_ip, opts})
  end

  # Removes the player outright, whoever holds them. Returns :not_queued
  # after a match, expiry or an earlier removal.
  def remove_player(id, user_id) do
    GenServer.call(__MODULE__, {:remove_player, id, user_id})
  end

  @doc """
  The calling process stops holding the player's seat. The player leaves the
  lobby (`:ok`) unless another of their tabs still holds it
  (`:held_elsewhere`); `:not_queued` after a match, expiry or a removal.
  """
  def release_player(id, user_id) do
    GenServer.call(__MODULE__, {:release_player, id, user_id})
  end

  def queue_players(id) do
    GenServer.call(__MODULE__, {:queue_players, id})
  end

  def queue_exists?(id) do
    GenServer.call(__MODULE__, {:queue_exists, id})
  end

  @doc """
  Whether the player has a seat in the lobby, held by a page or kept for
  them while they are away.
  """
  def seated?(id, user_id) do
    GenServer.call(__MODULE__, {:seated, id, user_id})
  end

  @doc """
  The short tag a lobby is recorded under in logs, site events and game
  logs: the first 8 characters of its id. Enough to tell lobbies apart, not
  enough to join one.
  """
  def lobby_tag(id) when is_binary(id), do: String.slice(id, 0, 8)

  # Server callbacks
  @impl true
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call({:create_queue, id, owner_id, remote_ip, opts}, _from, state) do
    handle_create_queue(id, owner_id, remote_ip, opts, state)
  end

  def handle_call({:reopen_queue, id, owner_id}, _from, state) do
    cond do
      not valid_queue_id?(id) ->
        {:reply, {:error, :invalid_id}, state}

      Map.has_key?(state.queues, id) ->
        {:reply, :ok, state}

      map_size(state.queues) >= max_queues() ->
        {:reply, {:error, :too_many_lobbies}, state}

      true ->
        Logger.info(
          "Private lobby #{lobby_tag(id)}: reopened for another game by " <>
            QueueHolders.short_id(owner_id)
        )

        {:reply, :ok, put_in(state.queues[id], new_queue(owner_id))}
    end
  end

  def handle_call({:add_player, id, {incoming_name, user_id}, remote_ip, opts}, from, state) do
    handle_add_player(id, incoming_name, user_id, remote_ip, {from, opts}, state)
  end

  def handle_call({:remove_player, id, user_id}, _from, state) do
    {result, state} = remove(state, id, user_id, "left")
    {:reply, result, state}
  end

  def handle_call({:release_player, id, user_id}, {caller, _tag}, state) do
    holders = QueueHolders.release(state.holders, caller, {id, user_id})
    state = %{state | holders: holders}

    cond do
      not seated?(state, id, user_id) ->
        {:reply, :not_queued, state}

      QueueHolders.held?(holders, {id, user_id}) ->
        {:reply, :held_elsewhere, state}

      true ->
        {result, state} = remove(state, id, user_id, "left")
        {:reply, result, state}
    end
  end

  def handle_call({:queue_players, id}, _from, state) do
    players = get_in(state.queues, [id, :players]) || []
    {:reply, players, state}
  end

  def handle_call({:queue_exists, id}, _from, state) do
    {:reply, valid_queue_id?(id) and Map.has_key?(state.queues, id), state}
  end

  def handle_call({:seated, id, user_id}, _from, state) do
    {:reply, seated?(state, id, user_id), state}
  end

  defp handle_create_queue(id, owner_id, remote_ip, opts, state) do
    now = System.system_time(:second)
    last = Map.get(state.last_created, owner_id, 0)

    cond do
      not valid_queue_id?(id) ->
        {:reply, {:error, :invalid_id}, state}

      Map.has_key?(state.queues, id) ->
        {:reply, {:error, :already_exists}, state}

      map_size(state.queues) >= max_queues() ->
        {:reply, {:error, :too_many_lobbies}, state}

      now - last < @create_cooldown_s ->
        {:reply, {:error, :too_soon}, state}

      not private_creation_allowed?(remote_ip) ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        Logger.info(
          "Private lobby #{lobby_tag(id)}: created by #{QueueHolders.short_id(owner_id)}"
        )

        queues = Map.put(state.queues, id, new_queue(owner_id))
        last_created = Map.put(state.last_created, owner_id, now)
        state = %{state | queues: queues, last_created: last_created}
        {:reply, :ok, seat_owner(state, id, owner_id, opts[:seat])}
    end
  end

  # The owner's seat waits for the lobby page they are being sent to.
  defp seat_owner(state, id, owner_id, name) when is_binary(name) do
    if ActiveGames.find_game(owner_id) do
      state
    else
      queue = shown_as(state.queues[id], owner_id, name)
      seated = [{Matchmaking.assign_display_name(name, []), owner_id}]
      state = put_in(state.queues[id], mark_empty(queue, seated))
      mark_away(state, {id, owner_id}, nil)
    end
  end

  defp seat_owner(state, _id, _owner_id, _name), do: state

  defp handle_add_player(id, incoming_name, user_id, remote_ip, holder, state) do
    case Map.fetch(state.queues, id) do
      {:ok, queue} -> admit_player(id, queue, incoming_name, user_id, remote_ip, holder, state)
      :error -> {:reply, {:error, :queue_not_found}, state}
    end
  end

  defp admit_player(id, queue, incoming_name, user_id, remote_ip, holder, state) do
    players = queue.players
    {{caller, _tag}, opts} = holder

    cond do
      Enum.any?(players, fn {_n, id2} -> id2 == user_id end) ->
        holders = QueueHolders.hold(state.holders, caller, {id, user_id}, opts[:on_drop])
        {:reply, :ok, clear_away(%{state | holders: holders}, {id, user_id})}

      ActiveGames.find_game(user_id) != nil ->
        # One game per session: rejoin (or abandon) the running game first.
        {:reply, {:error, :already_in_game}, state}

      not queue_admission_allowed?(remote_ip) ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        assigned_name = Matchmaking.assign_display_name(incoming_name, players)
        updated_players = players ++ [{assigned_name, user_id}]

        Logger.info(
          "Private lobby #{lobby_tag(id)}: #{QueueHolders.short_id(user_id)} joined " <>
            "(#{length(updated_players)} seated)"
        )

        holders = QueueHolders.hold(state.holders, caller, {id, user_id}, opts[:on_drop])

        queue = shown_as(queue, user_id, incoming_name)
        state = seat_players(id, queue, updated_players, %{state | holders: holders})
        {:reply, :ok, prune_holders(state)}
    end
  end

  # Stores the updated seating, starting (and removing) the lobby once it is
  # full. If the game could not start everyone stays seated for a retry.
  #
  # A kept seat can belong to a player who sat down at another table since
  # (the public queue, another lobby); they lose this seat rather than be
  # dealt into two games at once.
  defp seat_players(id, queue, players, state) when length(players) >= 4 do
    case Enum.filter(players, fn {_name, user_id} -> ActiveGames.find_game(user_id) end) do
      [] ->
        start_lobby_game(id, queue, players, state)

      busy ->
        for {_name, user_id} <- busy do
          Logger.info(
            "Private lobby #{lobby_tag(id)}: #{QueueHolders.short_id(user_id)} dropped: " <>
              "seated in another game"
          )
        end

        put_in(state.queues[id], mark_empty(queue, players -- busy))
    end
  end

  defp seat_players(id, queue, players, state) do
    put_in(state.queues[id], mark_empty(queue, players))
  end

  defp start_lobby_game(id, queue, players, state) do
    case Matchmaking.start_game(players,
           rematch_id: Ecto.UUID.generate(),
           queue: "private",
           lobby: lobby_tag(id)
         ) do
      :ok -> %{state | queues: Map.delete(state.queues, id)}
      {:error, _reason} -> put_in(state.queues[id], mark_empty(queue, players))
    end
  end

  # A process holding a seat exited. If it was the last one holding that
  # player: a page that lost its connection leaves them seated as away; any
  # other exit means they are gone, so free the seat before a game starts
  # with it.
  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    {entry, holders} = QueueHolders.down(state.holders, pid, ref)
    state = %{state | holders: holders}

    with %{key: {id, user_id} = key} <- entry,
         true <- seated?(state, id, user_id),
         false <- QueueHolders.held?(holders, key) do
      if connection_lost?(reason) do
        Logger.info(
          "Private lobby #{lobby_tag(id)}: #{QueueHolders.short_id(user_id)} away " <>
            "(connection lost, seat kept)"
        )

        {:noreply, mark_away(state, key, entry.on_drop)}
      else
        {_result, state} = remove(state, id, user_id, "dropped: its page closed without leaving")
        QueueHolders.notify_drop(entry)
        {:noreply, state}
      end
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:away_expired, {id, user_id} = key, ref}, state) do
    case state.away do
      %{^key => %{ref: ^ref} = entry} ->
        {_result, state} = remove(state, id, user_id, "dropped: away too long")
        QueueHolders.notify_drop(entry)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    {expired, live} =
      Map.split_with(state.queues, fn {_id, queue} ->
        empty_since = Map.get(queue, :empty_since)

        now - queue.created_at > @queue_ttl_ms or
          (is_integer(empty_since) and now - empty_since > @empty_queue_ttl_ms)
      end)

    for {id, queue} <- expired do
      Logger.info("Expiring private lobby #{lobby_tag(id)} (#{length(queue.players)} seated)")

      for {_name, user_id} <- queue.players do
        Phoenix.PubSub.broadcast(Website45sV3.PubSub, "user:#{user_id}", :queue_closed)
      end
    end

    cutoff = System.system_time(:second) - @create_cooldown_s

    last_created =
      state.last_created
      |> Enum.filter(fn {_owner, at} -> at > cutoff end)
      |> Map.new()

    schedule_sweep()
    {:noreply, prune_holders(%{state | queues: live, last_created: last_created})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # An empty lobby is *not* destroyed here. Every unmount of the lobby
  # LiveView ends up here, including a plain page refresh by the owner, who
  # has not joined yet, so deleting on empty would make the share link die
  # the moment anyone reloaded it or the last player left to rejoin. Empty
  # lobbies are reaped by the sweeper instead, after a grace period.
  defp remove(state, id, user_id, how) do
    case Map.fetch(state.queues, id) do
      {:ok, queue} ->
        updated_players = Enum.reject(queue.players, fn {_n, id2} -> id2 == user_id end)
        state = put_in(state.queues[id], mark_empty(queue, updated_players))

        if updated_players == queue.players do
          {:not_queued, state}
        else
          Logger.info(
            "Private lobby #{lobby_tag(id)}: #{QueueHolders.short_id(user_id)} #{how} " <>
              "(#{length(updated_players)} seated)"
          )

          {:ok, prune_holders(state)}
        end

      :error ->
        {:not_queued, state}
    end
  end

  defp seated?(state, id, user_id) do
    case Map.fetch(state.queues, id) do
      {:ok, queue} -> Enum.any?(queue.players, fn {_n, id2} -> id2 == user_id end)
      :error -> false
    end
  end

  # Forgets the holders, and the kept seats, of players no longer seated in a
  # live lobby.
  defp prune_holders(state) do
    holders =
      QueueHolders.prune(state.holders, fn {id, user_id} -> seated?(state, id, user_id) end)

    state.away
    |> Map.keys()
    |> Enum.reject(fn {id, user_id} -> seated?(state, id, user_id) end)
    |> Enum.reduce(%{state | holders: holders}, &clear_away(&2, &1))
  end

  # What a LiveView exits with when its socket closes under it: the phone
  # went to another app, the network dropped, or the page was reloaded.
  defp connection_lost?(reason), do: reason == {:shutdown, :closed}

  # Keeps the seat of a player nobody is holding, for `@away_grace_ms`. The
  # lobby shows who is seated from presence, so this process stands in for
  # the missing page there.
  defp mark_away(state, {id, user_id} = key, on_drop) do
    state = clear_away(state, key)
    ref = make_ref()
    timer = Process.send_after(self(), {:away_expired, key, ref}, away_grace_ms())

    with %{players: players} = queue <- state.queues[id],
         {seated_as, _id} <- List.keyfind(players, user_id, 1) do
      name = Map.get(queue[:shown] || %{}, user_id, seated_as)
      Presence.track(self(), topic(id), user_id, %{display_name: name, away: true})
    end

    put_in(state.away[key], %{ref: ref, timer: timer, on_drop: on_drop})
  end

  # The name a player's own page shows on their card, which an away card
  # keeps showing (the seated name may carry a number to tell players apart).
  defp shown_as(queue, user_id, name) do
    Map.put(queue, :shown, Map.put(queue[:shown] || %{}, user_id, name))
  end

  defp clear_away(state, {id, user_id} = key) do
    case Map.pop(state.away, key) do
      {nil, _away} ->
        state

      {%{timer: timer}, away} ->
        Process.cancel_timer(timer)
        Presence.untrack(self(), topic(id), user_id)
        %{state | away: away}
    end
  end

  defp topic(id), do: "private_queue:#{id}"

  defp away_grace_ms do
    Application.get_env(:website_45s_v3, :private_seat_grace_ms, @away_grace_ms)
  end

  defp new_queue(owner_id) do
    now = System.monotonic_time(:millisecond)
    %{players: [], owner: owner_id, created_at: now, empty_since: now}
  end

  # Stamps when a lobby became empty so the sweeper can reap abandoned lobbies
  # well before the full TTL, without punishing a refresh or a leave/rejoin.
  defp mark_empty(queue, []) do
    empty_since = Map.get(queue, :empty_since) || System.monotonic_time(:millisecond)
    %{Map.put(queue, :empty_since, empty_since) | players: []}
  end

  defp mark_empty(queue, players) do
    %{Map.put(queue, :empty_since, nil) | players: players}
  end

  defp valid_queue_id?(id) when is_binary(id), do: Regex.match?(@uuid_regex, id)
  defp valid_queue_id?(_), do: false

  defp max_queues do
    Application.get_env(:website_45s_v3, :max_private_queues, @default_max_queues)
  end

  defp queue_admission_allowed?(nil), do: true
  defp queue_admission_allowed?(remote_ip), do: RateLimiter.check_queue_join(remote_ip) == :ok

  defp private_creation_allowed?(nil), do: true

  defp private_creation_allowed?(remote_ip),
    do: RateLimiter.check_private_queue_create(remote_ip) == :ok

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
