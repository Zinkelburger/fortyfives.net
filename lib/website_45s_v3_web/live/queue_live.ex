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
           left_game_id: nil,
           last_bot_request: nil,
           page_title: "Private Game | Play 45s Online Free"
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
           tab: Map.get(params, "tab", "public"),
           left_game_id: nil,
           last_bot_request: nil,
           page_title: "Play 45s Online | Join a Forty Fives Card Game Free"
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
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_bot_request

    cond do
      last != nil and now - last < 3_000 ->
        {:noreply, put_flash(socket, :error, "Please wait a moment before adding another bot.")}

      true ->
        display_name = next_bot_name(socket.assigns.queue)

        result =
          case socket.assigns.live_action do
            :private_game ->
              Website45sV3.Game.BotSupervisor.start_private_bot(
                socket.assigns.private_id,
                display_name
              )

            _ ->
              Website45sV3.Game.BotSupervisor.start_bot(display_name)
          end

        case result do
          {:ok, _pid} ->
            {:noreply, assign(socket, :last_bot_request, now)}

          {:error, :too_many_bots} ->
            {:noreply,
             put_flash(socket, :error, "Too many bots are playing right now. Try again soon.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not add a bot. Try again.")}
        end
    end
  end

  # Ignore game updates that might still be broadcast to the user after they
  # navigate away from the game page. Without this clause the LiveView would
  # crash when it receives a `{:update_state, _}` message while the user is in
  # the queue.
  def handle_info({:update_state, _new_state}, socket) do
    {:noreply, socket}
  end

  def handle_info({:left_game, game_id}, socket) do
    {:noreply, assign(socket, left_game_id: game_id)}
  end

  def handle_info(:queue_closed, socket) do
    {:noreply,
     socket
     |> assign(in_queue: false)
     |> put_flash(:error, "This game lobby has expired. Please create a new one.")}
  end

  def handle_info(:game_end, socket) do
    {:noreply, socket}
  end

  def handle_info(:game_crash, socket), do: {:noreply, socket}

  def handle_info({:game_crash, _reason}, socket), do: {:noreply, socket}

  def handle_info(:auto_playing, socket), do: {:noreply, socket}

  def handle_info(:auto_play_disabled, socket), do: {:noreply, socket}

  def handle_info({:redirect, url}, socket) do
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

  defp next_bot_name(queue) do
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
          _ -> 0
        end
      end)

    next_number =
      case existing_bot_numbers do
        [] -> 1
        nums -> Enum.max(nums) + 1
      end

    "Bot" <> Integer.to_string(next_number)
  end

  def render(%{live_action: :private_game} = assigns) do
    ~H"""
    <div style="text-align: center; margin-top:10px;">
      <%= if @left_game_id do %>
        <div class="left-game-info" style="color:#d2e8f9; margin-bottom:1rem;">
          You have left your game.
          <.link navigate={~p"/game/#{@left_game_id}"} style="text-decoration: underline;">
            Rejoin here
          </.link>
        </div>
      <% end %>
      <p style="color: #d2e8f9; margin-bottom: 1rem;">
        Share this link with friends:
      </p>
      <div style="display: flex; justify-content: center; margin-bottom: 1rem;">
        <div class="share-link-group">
          <span id="share_link" class="share-link-url">{url(~p"/play/private/#{@private_id}")}</span>
          <button
            id="copy_button"
            type="button"
            class="share-link-copy"
            onclick="
              var url = document.getElementById('share_link').textContent.trim();
              var btn = this;
              navigator.clipboard.writeText(url).then(function() {
                btn.classList.add('copied');
                setTimeout(function() { btn.classList.remove('copied'); }, 1500);
              });
            "
          >
            <svg
              class="copy-icon"
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <rect x="9" y="9" width="13" height="13" rx="2" /><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
            </svg>
            <svg
              class="copy-check"
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <polyline points="20 6 9 17 4 12" />
            </svg>
            <span class="copy-icon">Copy</span>
            <span class="copy-check">Copied!</span>
          </button>
        </div>
      </div>

      <div class="queue-cards">
        <%= for {_user_id, presence} <- @queue do %>
          <%= for meta <- presence.metas do %>
            <div class="player-card">
              <p>{meta.display_name}</p>
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
              Join Private Game
            </button>
          </form>
          <button phx-click="request_bot" class="request-bot-button" title="Add a Bot">
            🤖
          </button>
        </div>
      <% else %>
        <p style="color: #d2e8f9; margin-bottom: 10px;">You are in the game lobby</p>
        <div style="display: inline-flex; align-items: center; gap: 0.5rem;">
          <form phx-submit="leave">
            <button
              type="submit"
              class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 red-button"
            >
              Leave
            </button>
          </form>
          <button phx-click="request_bot" class="request-bot-button" title="Add a Bot">
            🤖
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="tabs-container">
      <%= if @left_game_id do %>
        <div class="left-game-info" style="color:#d2e8f9; margin-bottom:1rem; text-align:center;">
          You have left your game.
          <.link navigate={~p"/game/#{@left_game_id}"} style="text-decoration: underline;">
            Rejoin here
          </.link>
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
        <div id="queue-root" style="text-align: center; margin-top:10px;">
          <h1 style="color: #d2e8f9; margin-bottom: 0px;">Queue</h1>
          <p style="color: #d2e8f9; margin-bottom: 20px;">4-players, teams</p>
          <div class="queue-cards">
            <%= for {_user_id, presence} <- @queue do %>
              <%= for meta <- presence.metas do %>
                <div class="player-card">
                  <p>{meta.display_name}</p>
                </div>
              <% end %>
            <% end %>
          </div>

          <%= if !@in_queue do %>
            <div style="display: inline-flex; align-items: center; gap: 0.5rem;">
              <form phx-submit="join">
                <button
                  id="join-queue-button"
                  type="submit"
                  class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
                >
                  Join Queue
                </button>
              </form>
              <!-- our new circular button -->
              <button phx-click="request_bot" class="request-bot-button" title="Request Bot">
                🤖
              </button>
            </div>
          <% else %>
            <p style="color: #d2e8f9; margin-bottom: 10px;">You are in the queue</p>
            <div style="display: inline-flex; align-items: center; gap: 0.5rem;">
              <form phx-submit="leave">
                <button
                  id="leave-queue-button"
                  type="submit"
                  class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 red-button"
                >
                  Leave Queue
                </button>
              </form>
              <button phx-click="request_bot" class="request-bot-button" title="Request Bot">
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
