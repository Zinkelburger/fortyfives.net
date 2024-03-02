defmodule Website45sV3Web.QueueAuthLive do
  use Website45sV3Web, :live_view
  alias Website45sV3Web.Presence
  alias Website45sV3.Game.QueueStarter

  def mount(_params, _session, socket) do
    if connected?(socket) do
      username = socket.assigns.current_user.username
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "queue")
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{username}")
    end

    # Fetch the current state of the queue.
    initial_queue = Presence.list("queue")

    {:ok, assign(socket, queue: initial_queue, in_queue: false)}
  end

  def terminate(_reason, socket) do
    username = socket.assigns.current_user.username
    Website45sV3.Game.QueueStarter.remove_player(username)
    :ok
  end

  def handle_event("join", _, socket) do
    username = socket.assigns.current_user.username
    Presence.track(self(), "queue", username, %{})

    QueueStarter.add_player(username)

    {:noreply, assign(socket, in_queue: true)}
  end

  def handle_event("leave", _, socket) do
    username = socket.assigns.current_user.username
    Presence.untrack(self(), "queue", username)

    QueueStarter.remove_player(username)

    {:noreply, assign(socket, in_queue: false, queue: Map.drop(socket.assigns.queue, [username]))}
  end

  def handle_info(:update_queue, socket) do
    queue = Presence.list("queue") |> Map.keys()
    {:noreply, assign(socket, queue: queue)}
  end

  def handle_info({:redirect, url}, socket) do
    {:noreply, push_redirect(socket, to: url)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          payload: %{joins: joins, leaves: leaves}
        },
        socket
      ) do
    queue = socket.assigns.queue

    updated_queue =
      queue
      |> Map.merge(joins)
      |> Map.drop(Map.keys(leaves))

    {:noreply, assign(socket, queue: updated_queue)}
  end

  def render(assigns) do
    ~H"""
    <div style="text-align: center; justify-content:center; margin-top:10px;">
      <h1 style="color: #d2e8f9; margin-bottom: 0px;">Queue</h1>
      <p style="color: #d2e8f9; margin-bottom: 20px;">4-players, teams</p>
      <div class="queue-cards">
        <%= for {name, _meta} <- @queue do %>
          <div class="player-card">
            <p><%= name %></p>
          </div>
        <% end %>
      </div>
      <%= if !@in_queue do %>
        <form phx-submit="join">
          <button
            type="submit"
            class="text-sm font-semibold leading-6 text-white active:text-white/80 rounded-lg bg-zinc-900 py-2 px-3 green-button"
          >
            Join Queue
          </button>
        </form>
      <% else %>
        <p style="color: #d2e8f9; margin-bottom: 10px;">You are in the queue</p>
        <form phx-submit="leave">
          <button
            type="submit"
            class="text-sm font-semibold leading-6 text-white active:text-white/80 rounded-lg bg-zinc-900 py-2 px-3 red-button"
          >
            Leave Queue
          </button>
        </form>
      <% end %>
    </div>
    """
  end
end
