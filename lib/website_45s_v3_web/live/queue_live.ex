defmodule Website45sV3Web.QueueLive do
  use Website45sV3Web, :live_view
  alias Website45sV3Web.Presence
  alias Website45sV3.Game.QueueStarter
  alias UUID

  def mount(params, session, socket) do
    display_name =
      if current_user = socket.assigns.current_user do
        current_user.username
      else
        "Anonymous"
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, "queue")
    end

    initial_queue = Presence.list("queue")
    user_id = Map.get(session, "user_id", "default_id")
    Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")

    socket =
      socket
      |> assign(
          user_id: user_id,
          display_name: display_name,
          queue: initial_queue,
          in_queue: false,
          # track which tab is showing
          tab: Map.get(params, "tab", "public")
        )

    {:ok, socket}
  end

  def terminate(_reason, socket) do
    {display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}
    QueueStarter.remove_player({display_name, user_id})
    :ok
  end

  def handle_event("join", _, socket) do
    IO.inspect("User id: #{socket.assigns.user_id}")
    if socket.assigns.user_id do
      {display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}
      Presence.track(self(), "queue", user_id, %{display_name: display_name})
      QueueStarter.add_player({display_name, user_id})
      {:noreply, assign(socket, in_queue: true)}
    else
      # TODO: Refresh the page if there is no user id
      raise "No user ID found in assigns"
    end
  end

  def handle_event("leave", _, socket) do
    {display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}
    Presence.untrack(self(), "queue", user_id)

    QueueStarter.remove_player({display_name, user_id})

    {:noreply, assign(socket, in_queue: false, queue: Map.drop(socket.assigns.queue, [user_id]))}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
  end

  def handle_event("create_private", _payload, socket) do
    # generate a random UUID for the private game
    private_id = UUID.generate()
    # redirect to e.g. /play/private/:id
    {:noreply,
    push_redirect(socket,
      to: Routes.live_path(socket, Website45sV3Web.QueueLive, :private_game, private_id)
    )}
  end

  def handle_info(:update_queue, socket) do
    queue = Presence.list("queue") |> Map.keys()
    {:noreply, assign(socket, queue: queue)}
  end

  def handle_info({:redirect, url}, socket) do
    IO.inspect("user id in assigns: #{socket.assigns.user_id}")
    {:noreply, push_redirect(socket, to: url, replace: :replace)}
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
    <div class="tabs-container">
      <!-- Tab nav -->
      <div class="tabs">
        <button
          phx-click="switch_tab"
          phx-value-tab="public"
          class={"tab #{@tab == "public" && "active"}"}
        >
          Public Queue
        </button>
        <button
          phx-click="switch_tab"
          phx-value-tab="private"
          class={"tab #{@tab == "private" && "active"}"}
        >
          Play a Friend
        </button>
      </div>

      <!-- Tab content -->
      <%= if @tab == "public" do %>
        <!-- your existing queue UI -->
        <div style="text-align: center; margin-top:10px;">
          <h1 style="color: #d2e8f9; margin-bottom: 0px;">Queue</h1>
          <p style="color: #d2e8f9; margin-bottom: 20px;">4-players, teams</p>
          <div class="queue-cards">
            <%= for {_user_id, presence} <- @queue do %>
              <%= for meta <- presence.metas do %>
                <div class="player-card">
                  <p><%= meta.display_name %></p>
                </div>
              <% end %>
            <% end %>
          </div>

          <%= if !@in_queue do %>
            <form phx-submit="join">
              <button
                type="submit"
                class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
              >
                Join Queue
              </button>
            </form>
          <% else %>
            <p style="color: #d2e8f9; margin-bottom: 10px;">You are in the queue</p>
            <form phx-submit="leave">
              <button
                type="submit"
                class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 red-button"
              >
                Leave Queue
              </button>
            </form>
          <% end %>
        </div>

      <% else %>
        <!-- Play a Friend tab -->
        <div style="text-align: center; margin-top: 2rem;">
          <p style="color: #d2e8f9; margin-bottom: 1rem;">
            Invite a friend with a private link:
          </p>
          <form phx-submit="create_private">
            <button
              type="submit"
              class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
            >
              Create Private Game
            </button>
          </form>
        </div>
      <% end %>
    </div>
    """
  end
end
