defmodule Website45sV3Web.QueueLive do
  use Website45sV3Web, :live_view
  alias Website45sV3Web.Presence
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Game.PrivateQueueManager
  alias UUID

  def mount(params, session, socket) do
    display_name =
      if current_user = socket.assigns.current_user do
        current_user.username
      else
        "Anonymous"
      end

    user_id = Map.get(session, "user_id", "default_id")
    Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")

    case socket.assigns.live_action do
      :private_game ->
        private_id = params["id"]

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Website45sV3.PubSub, "private_queue:#{private_id}")
        end

        initial_queue = Presence.list("private_queue:#{private_id}")

        {:ok,
         socket
         |> assign(
           user_id: user_id,
           display_name: display_name,
           queue: initial_queue,
           in_queue: false,
           private_id: private_id,
           left_game_info: nil
         )}

      _ ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Website45sV3.PubSub, "queue")
        end

        initial_queue = Presence.list("queue")

        {:ok,
         socket
         |> assign(
           user_id: user_id,
           display_name: display_name,
           queue: initial_queue,
           in_queue: false,
           # track which tab is showing
           tab: Map.get(params, "tab", "public"),
           left_game_info: nil
         )}
    end
  end

  def terminate(_reason, %{assigns: %{live_action: :private_game}} = socket) do
    {_display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}
    private_id = socket.assigns.private_id
    PrivateQueueManager.remove_player(private_id, user_id)
    :ok
  end

  def terminate(_reason, socket) do
    {display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}
    QueueStarter.remove_player({display_name, user_id})
    :ok
  end

  def handle_event("join", _, %{assigns: %{live_action: :private_game}} = socket) do
    if socket.assigns.user_id do
      {display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}
      private_id = socket.assigns.private_id
      Presence.track(self(), "private_queue:#{private_id}", user_id, %{display_name: display_name})
      PrivateQueueManager.add_player(private_id, {display_name, user_id})
      {:noreply, assign(socket, in_queue: true)}
    else
      raise "No user ID found in assigns"
    end
  end

  def handle_event("join", _, socket) do
    if socket.assigns.user_id do
      {display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}
      Presence.track(self(), "queue", user_id, %{display_name: display_name})
      QueueStarter.add_player({display_name, user_id})
      {:noreply, assign(socket, in_queue: true)}
    else
      raise "No user ID found in assigns"
    end
  end

  def handle_event("leave", _, %{assigns: %{live_action: :private_game}} = socket) do
    {_display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}
    private_id = socket.assigns.private_id
    Presence.untrack(self(), "private_queue:#{private_id}", user_id)
    PrivateQueueManager.remove_player(private_id, user_id)
    {:noreply, assign(socket, in_queue: false, queue: Map.drop(socket.assigns.queue, [user_id]))}
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
    private_id = UUID.uuid4()
    case PrivateQueueManager.create_queue(private_id, socket.assigns.user_id) do
      :ok ->
        {:noreply, push_navigate(socket, to: ~p"/play/private/#{private_id}")}
      {:error, :too_soon} ->
        {:noreply, put_flash(socket, :error, "Please wait before creating another link")}
    end
  end

  def handle_event("request_bot", _payload, socket) do
    queue = socket.assigns.queue

    existing_bot_numbers =
      queue
      |> Map.values()
      |> Enum.flat_map(fn %{metas: metas} ->
        Enum.map(metas, & &1.display_name)
      end)
      |> Enum.filter(&String.starts_with?(&1, "Bot"))
      |> Enum.map(fn "Bot" <> num ->
        case Integer.parse(num) do
          {int, ""} -> int
          _         -> 0
        end
      end)

    next_number =
      case existing_bot_numbers do
        [] -> 1
        nums -> Enum.max(nums) + 1
      end

    display_name = "Bot" <> Integer.to_string(next_number)

    Website45sV3.Game.BotSupervisor.start_bot(display_name)
    {:noreply, socket}
  end

  def handle_info(:update_queue, socket) do
    queue = Presence.list("queue") |> Map.keys()
    {:noreply, assign(socket, queue: queue)}
  end

  # Ignore game updates that might still be broadcast to the user after they
  # navigate away from the game page. Without this clause the LiveView would
  # crash when it receives a `{:update_state, _}` message while the user is in
  # the queue.
  def handle_info({:update_state, _new_state}, socket) do
    {:noreply, socket}
  end

  def handle_info({:left_game, game_id}, socket) do
    message =
      "You have left /game/#{game_id}. Please rejoin " <>
        "<a href=\"/game/#{game_id}\">here</a>"

    {:noreply, assign(socket, left_game_info: message)}
  end

  def handle_info(:game_end, socket) do
    {:noreply, socket}
  end

  def handle_info({:redirect, url}, socket) do
    IO.inspect("user id in assigns: #{socket.assigns.user_id}")
    {:noreply, push_navigate(socket, to: url, replace: :replace)}
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

  def render(%{live_action: :private_game} = assigns) do
    ~H"""
    <div style="text-align: center; margin-top:10px;">
      <%= if @left_game_info do %>
        <div class="left-game-info" style="color:#d2e8f9; margin-bottom:1rem;">
          <%= raw @left_game_info %>
        </div>
      <% end %>
      <p style="color: #d2e8f9; margin-bottom: 1rem;">
        Share this link with friends:
      </p>
      <div style="display: flex; justify-content: center; align-items: flex-start; margin-bottom: 1rem;">
        <button
          id="copy_button"
          type="button"
          title="Copy link"
          onclick='navigator.clipboard.writeText(document.getElementById("share_link").value),this.textContent="✔",setTimeout(()=>this.textContent="📋",300)'
          style="color: #d2e8f9; font-size: 1rem; background: none; border: 1px solid #fff; border-radius: 4px; cursor: pointer; padding: 0.45rem; opacity: 0.8; transition: opacity 0.2s;"
          onmouseover="this.style.opacity=1"
          onmouseout="this.style.opacity=0.8"
        >
          📋
        </button>
        <span
          id="share_link"
          onclick='
            navigator.clipboard.writeText(this.textContent);
            this.style.transition="background 0.3s";
            this.style.background="rgba(255,255,255,0.2)";
            setTimeout(()=>this.style.background="transparent",300)
          '
          style="
            display: inline-block;
            color: #d2e8f9;
            background: transparent;
            border: 1px solid #fff;
            border-radius: 4px;
            padding: 0.45rem;
            cursor: copy;
            user-select: all;
            font-size: 1rem;
          "
        >
          <%= url(~p"/play/private/#{@private_id}") %>
        </span>
      </div>

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
          <button type="submit" class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button">
            Join Private Game
          </button>
        </form>
      <% else %>
        <p style="color: #d2e8f9; margin-bottom: 10px;">You are in the game lobby</p>
        <form phx-submit="leave">
          <button type="submit" class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 red-button">
            Leave
          </button>
        </form>
      <% end %>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="tabs-container">
      <%= if @left_game_info do %>
        <div class="left-game-info" style="color:#d2e8f9; margin-bottom:1rem; text-align:center;">
          <%= raw @left_game_info %>
        </div>
      <% end %>
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
            <div style="display: inline-flex; align-items: center; gap: 0.5rem;">
              <form phx-submit="join">
                <button
                  type="submit"
                  class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
                >
                  Join Queue
                </button>
              </form>

              <!-- our new circular button -->
              <button
                phx-click="request_bot"
                class="request-bot-button"
              title="Request Bot"
              >
                🤖
              </button>
            </div>
          <% else %>
            <p style="color: #d2e8f9; margin-bottom: 10px;">You are in the queue</p>
            <div style="display: inline-flex; align-items: center; gap: 0.5rem;">
              <form phx-submit="leave">
                <button
                  type="submit"
                  class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 red-button"
                >
                  Leave Queue
                </button>
              </form>
              <button
                phx-click="request_bot"
                class="request-bot-button"
                title="Request Bot"
              >
                🤖
              </button>
            </div>
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
