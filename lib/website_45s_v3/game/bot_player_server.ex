defmodule Website45sV3.Game.BotPlayerServer do
  @moduledoc """
  A bot that occupies a real seat: it joins the public queue or a private
  lobby, waits for a game, and plays it with `BotPlayer`'s heuristics.
  """
  use GenServer

  alias Website45sV3Web.Presence
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.BotPlayer
  alias Website45sV3.Game.GameController

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
  def init({:public, display_name}) do
    init_bot(display_name, :public, "queue")
  end

  def init({:private, private_id, display_name}) do
    init_bot(display_name, {:private, private_id}, "private_queue:#{private_id}")
  end

  # Backwards-compatible: a bare display name means the public queue.
  def init(display_name) when is_binary(display_name) do
    init({:public, display_name})
  end

  defp init_bot(display_name, queue, queue_topic) do
    user_id = "bot_" <> UUID.uuid4()
    Presence.track(self(), queue_topic, user_id, %{display_name: display_name})
    Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")

    case queue do
      :public ->
        QueueStarter.add_player({display_name, user_id})

      {:private, private_id} ->
        PrivateQueueManager.add_player(private_id, {display_name, user_id})
    end

    Process.send_after(self(), :queue_idle_timeout, @queue_idle_timeout_ms)

    {:ok,
     %{
       user_id: user_id,
       display_name: display_name,
       queue: queue,
       queue_topic: queue_topic,
       game: nil
     }}
  end

  @impl true
  def handle_info({:redirect, "/game/" <> game_name}, state) do
    Presence.untrack(self(), state.queue_topic, state.user_id)
    Presence.track(self(), game_name, state.user_id, %{})

    # Just like a real player, fetch the current game state so the bot
    # can immediately act on its turn.
    case Registry.lookup(Website45sV3.Registry, game_name) do
      [{game_pid, _}] ->
        game_state = GameController.get_game_state(game_pid)
        send(self(), {:update_state, game_state})

      _ ->
        :ok
    end

    {:noreply, %{state | game: game_name}}
  end

  def handle_info({:update_state, new_state}, %{user_id: id, game: game_name} = state) do
    cond do
      game_name && new_state.phase == "Bidding" && new_state.current_player_id == id ->
        {bid, suit} = BotPlayer.pick_bid(new_state, id)
        schedule_move(game_name, {:player_bid, id, Integer.to_string(bid), suit, :bot})

      game_name && new_state.phase == "Discard" && id not in new_state.received_discards_from ->
        cards = BotPlayer.pick_discard(new_state, id)
        schedule_move(game_name, {:confirm_discard, id, cards, :bot})

      game_name && new_state.phase == "Playing" && new_state.current_player_id == id ->
        card = BotPlayer.pick_card(new_state, id)
        schedule_move(game_name, {:play_card, id, card, :bot})

      true ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:delayed_move, game_name, message}, state) do
    GameController.dispatch(game_name, message)
    {:noreply, state}
  end

  def handle_info(:queue_idle_timeout, %{game: nil} = state) do
    remove_from_queue(state)
    {:stop, :normal, state}
  end

  def handle_info(:queue_idle_timeout, state), do: {:noreply, state}

  def handle_info(:queue_closed, %{game: nil} = state) do
    remove_from_queue(state)
    {:stop, :normal, state}
  end

  def handle_info(:queue_closed, state), do: {:noreply, state}

  def handle_info(:game_end, state), do: {:stop, :normal, state}
  def handle_info(:game_crash, state), do: {:stop, :normal, state}
  def handle_info({:game_crash, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  defp schedule_move(game_name, message) do
    Process.send_after(self(), {:delayed_move, game_name, message}, 1000)
  end

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
