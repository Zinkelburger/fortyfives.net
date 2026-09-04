defmodule Website45sV3.Game.PrivateQueueManager do
  use GenServer
  require Logger

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.Matchmaking
  alias Website45sV3.Security.RateLimiter

  # How long an unfilled private lobby lives before it is cleaned up.
  @queue_ttl_ms 2 * 60 * 60 * 1000
  # A lobby nobody is sitting in is reaped much sooner, so abandoned links do
  # not hold seats against `max_queues`. Long enough to survive a refresh, a
  # reconnect, or a player leaving and rejoining.
  @empty_queue_ttl_ms 15 * 60 * 1000
  @sweep_interval_ms 5 * 60 * 1000
  # Minimum seconds between two lobby creations by the same user.
  @create_cooldown_s 120
  @default_max_queues 100
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  # Client API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{queues: %{}, last_created: %{}}, name: __MODULE__)
  end

  def create_queue(id, owner_id, remote_ip \\ nil) do
    GenServer.call(__MODULE__, {:create_queue, id, owner_id, remote_ip})
  end

  def add_player(id, {name, user_id}, remote_ip \\ nil) do
    GenServer.call(__MODULE__, {:add_player, id, {name, user_id}, remote_ip})
  end

  def remove_player(id, user_id) do
    GenServer.call(__MODULE__, {:remove_player, id, user_id})
  end

  def queue_players(id) do
    GenServer.call(__MODULE__, {:queue_players, id})
  end

  def queue_exists?(id) do
    GenServer.call(__MODULE__, {:queue_exists, id})
  end

  # Server callbacks
  @impl true
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call({:create_queue, id, owner_id}, _from, state) do
    handle_create_queue(id, owner_id, nil, state)
  end

  def handle_call({:create_queue, id, owner_id, remote_ip}, _from, state) do
    handle_create_queue(id, owner_id, remote_ip, state)
  end

  def handle_call({:add_player, id, {incoming_name, user_id}}, _from, state) do
    handle_add_player(id, incoming_name, user_id, nil, state)
  end

  def handle_call({:add_player, id, {incoming_name, user_id}, remote_ip}, _from, state) do
    handle_add_player(id, incoming_name, user_id, remote_ip, state)
  end

  def handle_call({:remove_player, id, user_id}, _from, state) do
    case Map.fetch(state.queues, id) do
      {:ok, queue} ->
        updated_players = Enum.reject(queue.players, fn {_n, id2} -> id2 == user_id end)

        # An empty lobby is *not* destroyed here. Every unmount of the lobby
        # LiveView calls this — including a plain page refresh by the owner, who
        # has not joined yet — so deleting on empty would make the share link
        # die the moment anyone reloaded it or the last player left to rejoin.
        # Empty lobbies are reaped by the sweeper instead, after a grace period.
        state = put_in(state.queues[id], mark_empty(queue, updated_players))

        {:reply, :ok, state}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:queue_players, id}, _from, state) do
    players = get_in(state.queues, [id, :players]) || []
    {:reply, players, state}
  end

  def handle_call({:queue_exists, id}, _from, state) do
    {:reply, valid_queue_id?(id) and Map.has_key?(state.queues, id), state}
  end

  defp handle_create_queue(id, owner_id, remote_ip, state) do
    now = System.system_time(:second)
    last = Map.get(state.last_created, owner_id, 0)

    cond do
      not valid_queue_id?(id) ->
        {:reply, {:error, :invalid_id}, state}

      map_size(state.queues) >= max_queues() ->
        {:reply, {:error, :too_many_lobbies}, state}

      now - last < @create_cooldown_s ->
        {:reply, {:error, :too_soon}, state}

      not private_creation_allowed?(remote_ip) ->
        {:reply, {:error, :rate_limited}, state}

      true ->
        queues = Map.put_new(state.queues, id, new_queue(owner_id))
        last_created = Map.put(state.last_created, owner_id, now)
        {:reply, :ok, %{state | queues: queues, last_created: last_created}}
    end
  end

  defp handle_add_player(id, incoming_name, user_id, remote_ip, state) do
    with {:ok, queue} <- Map.fetch(state.queues, id) do
      players = queue.players

      cond do
        Enum.any?(players, fn {_n, id2} -> id2 == user_id end) ->
          {:reply, :ok, state}

        ActiveGames.find_game(user_id) != nil ->
          # One game per session: rejoin (or abandon) the running game first.
          {:reply, {:error, :already_in_game}, state}

        not queue_admission_allowed?(remote_ip) ->
          {:reply, {:error, :rate_limited}, state}

        true ->
          assigned_name = Matchmaking.assign_display_name(incoming_name, players)
          updated_players = players ++ [{assigned_name, user_id}]

          if length(updated_players) >= 4 do
            case Matchmaking.start_game(updated_players) do
              :ok ->
                {:reply, :ok, %{state | queues: Map.delete(state.queues, id)}}

              {:error, _reason} ->
                state = put_in(state.queues[id], mark_empty(queue, updated_players))
                {:reply, :ok, state}
            end
          else
            state = put_in(state.queues[id], mark_empty(queue, updated_players))
            {:reply, :ok, state}
          end
      end
    else
      :error -> {:reply, {:error, :queue_not_found}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    {expired, live} =
      Map.split_with(state.queues, fn {_id, queue} ->
        empty_since = Map.get(queue, :empty_since)

        now - queue.created_at > @queue_ttl_ms or
          (is_integer(empty_since) and now - empty_since > @empty_queue_ttl_ms)
      end)

    for {_id, queue} <- expired do
      Logger.info("Expiring private lobby")

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
    {:noreply, %{state | queues: live, last_created: last_created}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
