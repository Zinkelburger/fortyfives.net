defmodule Website45sV3.Game.PrivateQueueManager do
  use GenServer
  require Logger

  alias Website45sV3.Game.Matchmaking

  # How long an unfilled private lobby lives before it is cleaned up.
  @queue_ttl_ms 2 * 60 * 60 * 1000
  @sweep_interval_ms 5 * 60 * 1000
  # Minimum seconds between two lobby creations by the same user.
  @create_cooldown_s 120

  # Client API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{queues: %{}, last_created: %{}}, name: __MODULE__)
  end

  def create_queue(id, owner_id) do
    GenServer.call(__MODULE__, {:create_queue, id, owner_id})
  end

  def add_player(id, {name, user_id}) do
    GenServer.call(__MODULE__, {:add_player, id, {name, user_id}})
  end

  def remove_player(id, user_id) do
    GenServer.call(__MODULE__, {:remove_player, id, user_id})
  end

  def queue_players(id) do
    GenServer.call(__MODULE__, {:queue_players, id})
  end

  # Server callbacks
  @impl true
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call({:create_queue, id, owner_id}, _from, state) do
    now = System.system_time(:second)
    last = Map.get(state.last_created, owner_id, 0)

    if now - last < @create_cooldown_s do
      {:reply, {:error, :too_soon}, state}
    else
      queues = Map.put_new(state.queues, id, new_queue(owner_id))
      last_created = Map.put(state.last_created, owner_id, now)
      {:reply, :ok, %{state | queues: queues, last_created: last_created}}
    end
  end

  def handle_call({:add_player, id, {incoming_name, user_id}}, _from, state) do
    queue = Map.get(state.queues, id, new_queue(nil))
    players = queue.players

    if Enum.any?(players, fn {_n, id2} -> id2 == user_id end) do
      {:reply, :ok, state}
    else
      assigned_name = Matchmaking.assign_display_name(incoming_name, players)
      updated_players = players ++ [{assigned_name, user_id}]

      if length(updated_players) >= 4 do
        case Matchmaking.start_game(updated_players) do
          :ok ->
            {:reply, :ok, %{state | queues: Map.delete(state.queues, id)}}

          {:error, _reason} ->
            state = put_in(state.queues[id], %{queue | players: updated_players})
            {:reply, :ok, state}
        end
      else
        state = put_in(state.queues[id], %{queue | players: updated_players})
        {:reply, :ok, state}
      end
    end
  end

  def handle_call({:remove_player, id, user_id}, _from, state) do
    case Map.fetch(state.queues, id) do
      {:ok, queue} ->
        updated_players = Enum.reject(queue.players, fn {_n, id2} -> id2 == user_id end)
        state = put_in(state.queues[id], %{queue | players: updated_players})
        {:reply, :ok, state}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:queue_players, id}, _from, state) do
    players = get_in(state.queues, [id, :players]) || []
    {:reply, players, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    {expired, live} =
      Map.split_with(state.queues, fn {_id, queue} ->
        now - queue.created_at > @queue_ttl_ms
      end)

    for {id, queue} <- expired do
      Logger.info("Expiring private lobby #{id}")

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
    %{players: [], owner: owner_id, created_at: System.monotonic_time(:millisecond)}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
