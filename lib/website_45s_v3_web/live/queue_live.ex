defmodule Website45sV3Web.QueueLive do
  use Website45sV3Web, :live_view
  alias Website45sV3Web.Presence
  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Game.PrivateQueueManager
  alias UUID

  # A player only ever needs 3 bots to fill their game, so that is the cap on
  # bots one session can have waiting in a queue. The global process cap
  # lives in BotSupervisor.
  @max_bots_per_requester 3

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
           active_game: fetch_active_game(user_id),
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
           active_game: fetch_active_game(user_id),
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

  def handle_event("join", _, socket) do
    {:noreply, join_queue(socket)}
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
    cond do
      socket.assigns.active_game ->
        {:noreply, put_flash(socket, :error, "Rejoin or abandon your current game first.")}

      true ->
        # generate a random UUID for the private game
        private_id = UUID.uuid4()

        case PrivateQueueManager.create_queue(private_id, socket.assigns.user_id) do
          :ok ->
            {:noreply, push_navigate(socket, to: ~p"/play/private/#{private_id}")}

          {:error, :too_soon} ->
            {:noreply, put_flash(socket, :error, "Please wait before creating another link")}
        end
    end
  end

  def handle_event("request_bot", _payload, socket) do
    cond do
      socket.assigns.active_game ->
        {:noreply, put_flash(socket, :error, "Rejoin or abandon your current game first.")}

      my_queued_bots(socket) >= @max_bots_per_requester ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You already have #{@max_bots_per_requester} bots waiting — join to start the game."
         )}

      true ->
        {:noreply, spawn_bots(socket, 1)}
    end
  end

  # One click to play right now: joins the queue if needed, then fills the
  # remaining seats with bots (the 4th seat starts the game).
  def handle_event("fill_bots", _payload, socket) do
    if socket.assigns.active_game do
      {:noreply, put_flash(socket, :error, "Rejoin or abandon your current game first.")}
    else
      socket = if socket.assigns.in_queue, do: socket, else: join_queue(socket)

      cond do
        # Join was refused; join_queue already set a flash explaining why.
        not socket.assigns.in_queue ->
          {:noreply, socket}

        # Joining completed a game (e.g. bots were already waiting) — the
        # redirect is on its way, don't seed the next queue with strays.
        ActiveGames.find_game(socket.assigns.user_id) != nil ->
          {:noreply, socket}

        true ->
          {:noreply, spawn_bots(socket, max(4 - queue_size(socket), 0))}
      end
    end
  end

  def handle_event("abandon_game", _payload, socket) do
    case socket.assigns.active_game do
      nil ->
        {:noreply, socket}

      %{id: game_id} ->
        GameController.dispatch(game_id, {:abandon_game, socket.assigns.user_id})
        # The dispatch is async; free the session now so an immediate
        # "Join Queue" click isn't refused while the game catches up.
        ActiveGames.remove_player(socket.assigns.user_id)

        {:noreply,
         socket
         |> assign(active_game: nil)
         |> put_flash(:info, "You left your game. A bot will finish it for you.")}
    end
  end

  # Ignore game updates that might still be broadcast to the user after they
  # navigate away from the game page. Without this clause the LiveView would
  # crash when it receives a `{:update_state, _}` message while the user is in
  # the queue.
  def handle_info({:update_state, _new_state}, socket) do
    {:noreply, socket}
  end

  def handle_info(:queue_closed, socket) do
    {:noreply,
     socket
     |> assign(in_queue: false)
     |> put_flash(:error, "This game lobby has expired. Please create a new one.")}
  end

  # The user's running game ended or crashed while they were on the lobby
  # page: retire the "game in progress" card.
  def handle_info(:game_end, socket) do
    {:noreply, assign(socket, active_game: nil)}
  end

  def handle_info(:game_crash, socket), do: {:noreply, assign(socket, active_game: nil)}

  def handle_info({:game_crash, _reason}, socket),
    do: {:noreply, assign(socket, active_game: nil)}

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

  ## Queue helpers

  defp queue_topic(%{assigns: %{live_action: :private_game, private_id: id}}),
    do: "private_queue:#{id}"

  defp queue_topic(_socket), do: "queue"

  # Adds the user to their queue and tracks presence. On refusal (their
  # session is still seated in a running game) refreshes the banner instead.
  defp join_queue(socket) do
    {display_name, user_id} = {socket.assigns.display_name, socket.assigns.user_id}

    result =
      case socket.assigns.live_action do
        :private_game ->
          PrivateQueueManager.add_player(socket.assigns.private_id, {display_name, user_id})

        _ ->
          QueueStarter.add_player({display_name, user_id})
      end

    case result do
      :ok ->
        Presence.track(self(), queue_topic(socket), user_id, %{display_name: display_name})
        assign(socket, in_queue: true)

      {:error, :already_in_game} ->
        socket
        |> assign(active_game: fetch_active_game(user_id))
        |> put_flash(:error, "You already have a game in progress.")
    end
  end

  # Authoritative queue size (the assigns copy lags behind presence
  # broadcasts). Bots register themselves synchronously on spawn, so this is
  # accurate immediately after each spawn.
  defp queue_size(%{assigns: %{live_action: :private_game, private_id: id}}) do
    id |> PrivateQueueManager.queue_players() |> length()
  end

  defp queue_size(_socket), do: QueueStarter.player_count()

  defp my_queued_bots(socket) do
    user_id = socket.assigns.user_id

    socket
    |> queue_topic()
    |> Presence.list()
    |> Map.values()
    |> Enum.count(fn %{metas: metas} ->
      Enum.any?(metas, &(Map.get(&1, :requester) == user_id))
    end)
  end

  defp spawn_bots(socket, 0), do: socket

  defp spawn_bots(socket, count) do
    # Read presence fresh: the assigns copy may not include bots spawned a
    # moment ago, and duplicate names confuse the table.
    names = socket |> queue_topic() |> Presence.list() |> next_bot_names(count)

    Enum.reduce_while(names, socket, fn name, socket ->
      result =
        case socket.assigns.live_action do
          :private_game ->
            BotSupervisor.start_private_bot(
              socket.assigns.private_id,
              name,
              socket.assigns.user_id
            )

          _ ->
            BotSupervisor.start_bot(name, socket.assigns.user_id)
        end

      case result do
        {:ok, _pid} ->
          {:cont, socket}

        {:error, :too_many_bots} ->
          {:halt,
           put_flash(socket, :error, "Too many bots are playing right now. Try again soon.")}

        {:error, _reason} ->
          {:halt, put_flash(socket, :error, "Could not add a bot. Try again.")}
      end
    end)
  end

  defp next_bot_names(presence, count) do
    existing_bot_numbers =
      presence
      |> Map.values()
      |> Enum.flat_map(fn %{metas: metas} ->
        Enum.map(metas, & &1.display_name)
      end)
      |> Enum.filter(&String.starts_with?(&1, "Bot"))
      |> Enum.flat_map(fn "Bot" <> num ->
        case Integer.parse(num) do
          {int, ""} -> [int]
          _ -> []
        end
      end)

    start = Enum.max(existing_bot_numbers, fn -> 0 end) + 1

    Enum.map(start..(start + count - 1), &("Bot" <> Integer.to_string(&1)))
  end

  ## Active-game banner

  # Resolves the user's running game (if any) into what the banner needs.
  # Falls back to nil if the game died between the lookup and the state read.
  defp fetch_active_game(user_id) do
    with game_name when is_binary(game_name) <- ActiveGames.find_game(user_id),
         [{game_pid, _}] <- Registry.lookup(Website45sV3.Registry, game_name) do
      try do
        game_state = GameController.get_game_state(game_pid)

        others =
          game_state.player_ids
          |> Enum.reject(&(&1 == user_id))
          |> Enum.map(&Map.get(game_state.player_map, &1, "Anonymous"))

        %{id: game_name, players: others}
      catch
        :exit, _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp active_game_card(assigns) do
    ~H"""
    <div class="active-game-card">
      <p class="active-game-title">You have a game in progress</p>
      <p :if={@game.players != []} class="active-game-players">
        Playing with {Enum.join(@game.players, ", ")}
      </p>
      <div class="active-game-actions">
        <.link
          id="rejoin-game-button"
          navigate={~p"/game/#{@game.id}"}
          class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
        >
          Rejoin Game
        </.link>
        <button
          id="abandon-game-button"
          phx-click="abandon_game"
          data-confirm="Abandon this game? A bot will play your seat for the rest of the game."
          class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 red-button"
        >
          Abandon
        </button>
      </div>
    </div>
    """
  end

  def render(%{live_action: :private_game} = assigns) do
    ~H"""
    <div style="text-align: center; margin-top:10px;">
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

      <%= if @active_game do %>
        <.active_game_card game={@active_game} />
      <% else %>
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
            <button
              id="fill-bots-button"
              phx-click="fill_bots"
              class="text-sm font-semibold leading-6 text-white rounded-lg py-2 px-3 fill-bots-button"
            >
              Fill with Bots
            </button>
            <button phx-click="request_bot" class="request-bot-button" title="Add a Bot">
              🤖
            </button>
          </div>
        <% end %>
      <% end %>
    </div>
    """
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

          <%= if @active_game do %>
            <.active_game_card game={@active_game} />
          <% else %>
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
                <button
                  id="play-vs-bots-button"
                  phx-click="fill_bots"
                  class="text-sm font-semibold leading-6 text-white rounded-lg py-2 px-3 fill-bots-button"
                >
                  Play vs Bots
                </button>
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
                <button
                  id="fill-bots-button"
                  phx-click="fill_bots"
                  class="text-sm font-semibold leading-6 text-white rounded-lg py-2 px-3 fill-bots-button"
                >
                  Fill with Bots
                </button>
                <button phx-click="request_bot" class="request-bot-button" title="Request Bot">
                  🤖
                </button>
              </div>
            <% end %>
          <% end %>
        </div>
      <% else %>
        <!-- Play a Friend tab -->
        <div style="text-align: center; margin-top: 2rem;">
          <p style="color: #d2e8f9; margin-bottom: 1rem;">
            Invite a friend with a private link:
          </p>
          <%= if @active_game do %>
            <.active_game_card game={@active_game} />
          <% else %>
            <form phx-submit="create_private">
              <button
                type="submit"
                class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
              >
                Create Private Game
              </button>
            </form>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
