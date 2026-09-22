defmodule Website45sV3.Game.BotPlayerServer do
  @moduledoc """
  A bot that occupies a real seat: it joins the public queue or a private
  lobby and waits for a game. Once the game starts the bot's moves are
  driven by the game process itself (see `GameController`); this process
  only holds the seat's presence and goes away when the game does.
  """
  use GenServer

  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3Web.Presence

  # A bot that has not been matched into a game after this long removes
  # itself from the queue instead of lingering forever.
  @queue_idle_timeout_ms 10 * 60 * 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(arg) do
    super(arg)
    |> Map.put(:restart, :temporary)
  end

  @impl true
  def init({:public, display_name, requester}) do
    init_bot(display_name, :public, "queue", requester)
  end

  def init({:private, private_id, display_name, requester}) do
    init_bot(display_name, {:private, private_id}, "private_queue:#{private_id}", requester)
  end

  def init({:public, display_name}), do: init({:public, display_name, nil})

  def init({:private, private_id, display_name}),
    do: init({:private, private_id, display_name, nil})

  # Backwards-compatible: a bare display name means the public queue.
  def init(display_name) when is_binary(display_name) do
    init({:public, display_name, nil})
  end

  defp init_bot(display_name, queue, queue_topic, requester) do
    user_id = "bot_" <> Ecto.UUID.generate()

    # Subscribe *before* joining: filling the 4th seat starts the game and
    # broadcasts the redirect synchronously from inside `add_player`, so a
    # bot that subscribed afterwards would never hear about its own game.
    Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")

    # Join the queue before tracking presence. A private lobby can be gone by
    # now (it filled, was swept, or the link expired); tracking first would
    # leave a bot showing in the lobby for the whole idle timeout without ever
    # being in `queue.players`, which also makes `fill_bots` under-spawn.
    case join_queue(queue, display_name, user_id) do
      :ok ->
        Presence.track(self(), queue_topic, user_id, %{
          display_name: display_name,
          requester: requester
        })

        Process.send_after(self(), :queue_idle_timeout, @queue_idle_timeout_ms)

        {:ok,
         %{
           user_id: user_id,
           display_name: display_name,
           queue: queue,
           queue_topic: queue_topic,
           game: nil,
           game_monitor: nil
         }}

      {:error, reason} ->
        {:stop, {:shutdown, reason}}
    end
  end

  defp join_queue(:public, display_name, user_id) do
    QueueStarter.add_player({display_name, user_id})
  end

  defp join_queue({:private, private_id}, display_name, user_id) do
    PrivateQueueManager.add_player(private_id, {display_name, user_id})
  end

  @impl true
  def handle_info({:redirect, "/game/" <> game_name}, state) do
    Presence.untrack(self(), state.queue_topic, state.user_id)

    # Follow the game's life: if the game process dies without running its
    # terminate callback (a kill), this bot must not linger holding one of
    # the supervisor's slots.
    case Registry.lookup(Website45sV3.Registry, game_name) do
      [{game_pid, _}] ->
        Presence.track(self(), game_name, state.user_id, %{})
        ref = Process.monitor(game_pid)
        {:noreply, %{state | game: game_name, game_monitor: ref}}

      [] ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{game_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:queue_idle_timeout, %{game: nil} = state) do
    remove_from_queue(state)
    {:stop, :normal, state}
  end

  def handle_info(:queue_closed, %{game: nil} = state) do
    remove_from_queue(state)
    {:stop, :normal, state}
  end

  def handle_info(:game_end, state), do: {:stop, :normal, state}
  def handle_info(:game_crash, state), do: {:stop, :normal, state}
  def handle_info({:game_crash, _reason}, state), do: {:stop, :normal, state}

  # Game state broadcasts, late queue notices, etc. are of no interest: the
  # game process computes this seat's moves.
  def handle_info(_msg, state), do: {:noreply, state}

  defp remove_from_queue(state) do
    case state.queue do
      :public ->
        QueueStarter.remove_player({state.display_name, state.user_id})

      {:private, private_id} ->
        PrivateQueueManager.remove_player(private_id, state.user_id)
    end
  end

  @impl true
  def terminate(_reason, state) do
    Presence.untrack(self(), state.queue_topic, state.user_id)

    if state.game do
      Presence.untrack(self(), state.game, state.user_id)
    end

    :ok
  end
end
