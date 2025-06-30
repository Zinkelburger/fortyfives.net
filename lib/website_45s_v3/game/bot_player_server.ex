defmodule Website45sV3.Game.BotPlayerServer do
  use GenServer
  alias Website45sV3Web.Presence
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Game.BotPlayer
  alias UUID

  def start_link(display_name) do
    GenServer.start_link(__MODULE__, display_name)
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
    {:noreply, %{state | game: game_name}}
  end

  def handle_info({:update_state, new_state}, %{user_id: id, game: game_name} = state) do
    if game_name && new_state.current_player_id == id do
      case new_state.phase do
        "Bidding" ->
          {bid, suit} = BotPlayer.pick_bid(new_state, id)
          schedule_move(game_name, {:player_bid, id, Integer.to_string(bid), suit, :bot})
        "Discard" ->
          cards = BotPlayer.pick_discard(new_state, id)
          schedule_move(game_name, {:confirm_discard, id, cards, :bot})
        "Playing" ->
          card = BotPlayer.pick_card(new_state, id)
          schedule_move(game_name, {:play_card, id, card, :bot})
        _ ->
          :ok
      end
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
    :ok
  end
end
