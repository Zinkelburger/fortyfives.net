defmodule Website45sV3.Game.BotPlayerServer do
  use GenServer
  alias Website45sV3Web.Presence
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Game.BotPlayer
  alias UUID

  def start_link(display_name) do
    GenServer.start_link(__MODULE__, display_name)
  end

  def child_spec(arg) do
    super(arg)
    |> Map.put(:restart, :temporary)
  end

  @impl true
  def init(display_name) do
    user_id = "bot_" <> UUID.uuid4()
    Presence.track(self(), "queue", user_id, %{display_name: display_name})
    Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")
    QueueStarter.add_player({display_name, user_id})
    {:ok, %{user_id: user_id, game: nil}}
  end

  @impl true
  def handle_info({:redirect, "/game/" <> game_name}, state) do
    Presence.untrack(self(), "queue", state.user_id)
    Phoenix.PubSub.subscribe(Website45sV3.PubSub, game_name)
    Presence.track(self(), game_name, state.user_id, %{})

    # Just like a real player, fetch the current game state so the bot
    # can immediately act on its turn. We lookup the GameController
    # process via the Registry and send ourselves an `:update_state`
    # message with the initial state.
    case Registry.lookup(Website45sV3.Registry, game_name) do
      [{game_pid, _}] ->
        game_state = Website45sV3.Game.GameController.get_game_state(game_pid)
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
    Phoenix.PubSub.broadcast(Website45sV3.PubSub, game_name, message)
    {:noreply, state}
  end

  def handle_info(:game_end, state), do: {:stop, :normal, state}
  def handle_info(:game_crash, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  defp schedule_move(game_name, message) do
    Process.send_after(self(), {:delayed_move, game_name, message}, 1000)
  end

  @impl true
  def terminate(_reason, state) do
    Presence.untrack(self(), "queue", state.user_id)
    if state.game do
      Presence.untrack(self(), state.game, state.user_id)
    end
    :ok
  end
end
