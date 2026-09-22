defmodule Website45sV3Web.QueueLive do
  @moduledoc """
  The lobby page.

  `/play` shows the public matchmaking queue (plus a "Play a Friend" tab for
  creating private lobbies) and `/play/private/:id` shows one private lobby.
  Queue membership is owned by `QueueStarter` / `PrivateQueueManager`; the
  list of who is waiting is rendered from `Presence`, keyed by session user
  id so a player with two tabs open still shows as one card.
  """
  use Website45sV3Web, :live_view

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameController
  alias Website45sV3.Game.PrivateQueueManager
  alias Website45sV3.Game.QueueStarter
  alias Website45sV3.Security.RateLimiter
  alias Website45sV3.Turnstile
  alias Website45sV3Web.Presence

  # A player only ever needs 3 bots to fill their game, so that is the cap on
  # bots one session can have waiting in a queue. The global process cap
  # lives in BotSupervisor.
  @max_bots_per_requester 3

  @tabs ~w(public private)

  @public_title "Play 45s Online | Join a Forty Fives Card Game Free"
  @private_title "Private Game | Play 45s Online Free"
  @invalid_link_message "That private game link is invalid or has expired."
  @active_game_message "Rejoin or abandon your current game first."

  def mount(params, session, socket) do
    user_id = session_user_id(session)
    Phoenix.PubSub.subscribe(Website45sV3.PubSub, "user:#{user_id}")

    socket =
      assign(socket,
        user_id: user_id,
        display_name: display_name(socket.assigns.current_user),
        client_ip: client_ip(socket) || "session:#{user_id}",
        in_queue: false,
        presence_ref: nil,
        private_id: nil,
        tab: "public"
      )

    case socket.assigns.live_action do
      :private_game -> mount_private(socket, params["id"])
      _ -> mount_public(socket)
    end
  end

  defp mount_public(socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Website45sV3.PubSub, "queue")

    {:ok,
     assign(socket,
       queue: Presence.list("queue"),
       active_game: fetch_active_game(socket.assigns.user_id),
       page_title: @public_title
     )}
  end

  defp mount_private(socket, private_id) do
    if PrivateQueueManager.queue_exists?(private_id) do
      topic = "private_queue:#{private_id}"
      if connected?(socket), do: Phoenix.PubSub.subscribe(Website45sV3.PubSub, topic)

      {:ok,
       assign(socket,
         private_id: private_id,
         queue: Presence.list(topic),
         active_game: fetch_active_game(socket.assigns.user_id),
         page_title: @private_title
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, @invalid_link_message)
       |> redirect(to: ~p"/play")}
    end
  end

  # Every browser request passes through `UserAuth.fetch_current_user`,
  # which stores a per-session id. A missing id means that pipeline was
  # bypassed; failing loudly beats sharing one identity between every
  # anonymous player.
  defp session_user_id(%{"user_id" => user_id}) when is_binary(user_id), do: user_id
  defp session_user_id(_session), do: raise("user_id missing from the session")

  defp display_name(%{username: username}), do: username
  defp display_name(_anonymous), do: "Anonymous"

  # The active tab lives in the URL (`/play?tab=private`) so it can be linked
  # to and survives a reload. Unknown values fall back to the public queue.
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, tab: tab_from_params(params))}
  end

  defp tab_from_params(%{"tab" => tab}) when tab in @tabs, do: tab
  defp tab_from_params(_params), do: "public"

  # Runs for aborted mounts too (an invalid private link redirects straight
  # out of `mount/3`), hence the tolerant `assigns[...]` read. Only a LiveView
  # that joined the queue itself may remove the player, and only when no other
  # tab of the same session is still tracked on the topic; otherwise closing a
  # second tab evicted the first tab's entry while it still said "in queue".
  def terminate(_reason, socket) do
    if socket.assigns[:in_queue] and not other_tabs_in_queue?(socket) do
      remove_from_queue(socket)
    end

    :ok
  end

  defp other_tabs_in_queue?(socket) do
    %{user_id: user_id, presence_ref: ref} = socket.assigns

    case Presence.get_by_key(queue_topic(socket), user_id) do
      %{metas: metas} -> Enum.any?(metas, &(&1.phx_ref != ref))
      [] -> false
    end
  end

  def handle_event("join", _params, %{assigns: %{in_queue: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("join", _params, socket) do
    {:noreply, join_queue(socket)}
  end

  def handle_event("leave", _params, socket) do
    topic = queue_topic(socket)
    Presence.untrack(self(), topic, socket.assigns.user_id)
    remove_from_queue(socket)

    {:noreply, assign(socket, in_queue: false, presence_ref: nil, queue: Presence.list(topic))}
  end

  def handle_event("create_private", _params, socket) do
    if socket.assigns.active_game do
      {:noreply, put_flash(socket, :error, @active_game_message)}
    else
      create_private_queue(socket)
    end
  end

  def handle_event("request_bot", _params, socket) do
    cond do
      socket.assigns.active_game ->
        {:noreply, put_flash(socket, :error, @active_game_message)}

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
  def handle_event("fill_bots", _params, socket) do
    if socket.assigns.active_game do
      {:noreply, put_flash(socket, :error, @active_game_message)}
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

  def handle_event("abandon_game", _params, socket) do
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

  defp create_private_queue(socket) do
    private_id = Ecto.UUID.generate()

    case PrivateQueueManager.create_queue(
           private_id,
           socket.assigns.user_id,
           socket.assigns.client_ip
         ) do
      :ok ->
        {:noreply, push_navigate(socket, to: ~p"/play/private/#{private_id}")}

      {:error, :too_soon} ->
        {:noreply, put_flash(socket, :error, "Please wait before creating another link")}

      {:error, :too_many_lobbies} ->
        {:noreply, put_flash(socket, :error, "Private games are temporarily at capacity")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many private games created from your network")}

      {:error, reason} when reason in [:invalid_id, :already_exists] ->
        {:noreply, put_flash(socket, :error, "Unable to create a private game")}
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
     |> assign(in_queue: false, presence_ref: nil)
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

  # The game page lives in a different `live_session`, so this has to be a
  # full redirect: `push_navigate` across live sessions only logs a warning
  # and then falls back to the same reload.
  def handle_info({:redirect, url}, socket) do
    {:noreply, redirect(socket, to: url)}
  end

  # Presence is authoritative, so re-read it rather than merging the diff by
  # hand (a hand merge dropped a user entirely when only one of their tabs
  # left).
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, queue: Presence.list(queue_topic(socket)))}
  end

  ## Queue helpers

  defp queue_topic(%{assigns: %{live_action: :private_game, private_id: id}}),
    do: "private_queue:#{id}"

  defp queue_topic(_socket), do: "queue"

  # Adds the user to their queue and tracks presence. On refusal (their
  # session is still seated in a running game) refreshes the banner instead.
  defp join_queue(socket) do
    %{display_name: display_name, user_id: user_id} = socket.assigns

    result =
      case socket.assigns.live_action do
        :private_game ->
          PrivateQueueManager.add_player(
            socket.assigns.private_id,
            {display_name, user_id},
            socket.assigns.client_ip
          )

        _ ->
          QueueStarter.add_player({display_name, user_id}, socket.assigns.client_ip)
      end

    case result do
      :ok ->
        {:ok, ref} =
          Presence.track(self(), queue_topic(socket), user_id, %{display_name: display_name})

        assign(socket, in_queue: true, presence_ref: ref)

      {:error, :already_in_game} ->
        socket
        |> assign(active_game: fetch_active_game(user_id))
        |> put_flash(:error, "You already have a game in progress.")

      {:error, :rate_limited} ->
        put_flash(
          socket,
          :error,
          "Too many queue joins from your network. Please wait and try again."
        )

      {:error, :queue_not_found} ->
        socket
        |> put_flash(:error, @invalid_link_message)
        |> push_navigate(to: ~p"/play")
    end
  end

  defp remove_from_queue(%{assigns: %{live_action: :private_game} = assigns}) do
    PrivateQueueManager.remove_player(assigns.private_id, assigns.user_id)
  end

  defp remove_from_queue(%{assigns: assigns}) do
    QueueStarter.remove_player({assigns.display_name, assigns.user_id})
  end

  defp client_ip(socket) do
    Turnstile.client_ip(
      Phoenix.LiveView.get_connect_info(socket, :x_headers),
      Phoenix.LiveView.get_connect_info(socket, :peer_data)
    )
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
      case charge_and_start_bot(socket, name) do
        {:ok, _pid} ->
          {:cont, socket}

        {:error, :too_many_bots} ->
          {:halt,
           put_flash(socket, :error, "Too many bots are playing right now. Try again soon.")}

        {:error, :rate_limited} ->
          {:halt,
           put_flash(
             socket,
             :error,
             "You've added a lot of bots recently. Try again in a few minutes."
           )}

        {:error, :queue_not_found} ->
          {:halt,
           socket
           |> put_flash(:error, @invalid_link_message)
           |> push_navigate(to: ~p"/play")}

        {:error, _reason} ->
          {:halt, put_flash(socket, :error, "Could not add a bot. Try again.")}
      end
    end)
  end

  # The per-session cap resets with a fresh cookie; this per-network budget
  # keeps a single client from taking the whole shared bot pool.
  defp charge_and_start_bot(socket, name) do
    with :ok <- RateLimiter.check_bot_spawn(socket.assigns.client_ip) do
      start_bot(socket, name)
    end
  end

  defp start_bot(%{assigns: %{live_action: :private_game} = assigns}, name) do
    BotSupervisor.start_private_bot(assigns.private_id, name, assigns.user_id)
  end

  defp start_bot(%{assigns: assigns}, name) do
    BotSupervisor.start_bot(name, assigns.user_id)
  end

  defp next_bot_names(presence, count) do
    existing_bot_numbers =
      presence
      |> Map.values()
      |> Enum.flat_map(fn %{metas: metas} -> Enum.map(metas, & &1.display_name) end)
      |> Enum.flat_map(&bot_number/1)

    start = Enum.max(existing_bot_numbers, fn -> 0 end) + 1

    Enum.map(start..(start + count - 1)//1, &("Bot" <> Integer.to_string(&1)))
  end

  defp bot_number("Bot" <> num) do
    case Integer.parse(num) do
      {int, ""} -> [int]
      _ -> []
    end
  end

  defp bot_number(_name), do: []

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

  ## Components

  attr :game, :map, required: true

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
          href={~p"/game/#{@game.id}"}
          class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
        >
          Rejoin Game
        </.link>
        <button
          id="abandon-game-button"
          type="button"
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

  # One card per waiting player. Presence keeps one meta per connected tab,
  # so the first meta stands in for the user.
  attr :queue, :map, required: true

  defp queue_cards(assigns) do
    ~H"""
    <div class="queue-cards" aria-label="Players waiting">
      <div :for={{_user_id, %{metas: [meta | _]}} <- @queue} class="player-card">
        <p>{meta.display_name}</p>
      </div>
    </div>
    """
  end

  # Join / leave / bot controls shared by the public queue and private lobbies.
  attr :in_queue, :boolean, required: true
  attr :active_game, :any, required: true
  attr :join_label, :string, required: true
  attr :leave_label, :string, required: true
  attr :waiting_message, :string, required: true

  defp queue_actions(%{active_game: %{}} = assigns) do
    ~H"""
    <.active_game_card game={@active_game} />
    """
  end

  defp queue_actions(%{in_queue: false} = assigns) do
    ~H"""
    <div class="queue-actions">
      <button
        id="join-queue-button"
        type="button"
        phx-click="join"
        class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
      >
        {@join_label}
      </button>
      <.add_bot_button />
    </div>
    """
  end

  defp queue_actions(assigns) do
    ~H"""
    <p class="queue-status">{@waiting_message}</p>
    <div class="queue-actions">
      <button
        id="leave-queue-button"
        type="button"
        phx-click="leave"
        class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 red-button"
      >
        {@leave_label}
      </button>
      <button
        id="fill-bots-button"
        type="button"
        phx-click="fill_bots"
        class="text-sm font-semibold leading-6 text-white rounded-lg py-2 px-3 fill-bots-button"
      >
        Fill with Bots
      </button>
      <.add_bot_button />
    </div>
    """
  end

  defp add_bot_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="request_bot"
      class="text-sm font-semibold leading-6 text-white rounded-lg py-2 px-3 fill-bots-button request-bot-button"
      aria-label="Add a bot"
      title="Add a bot"
    >
      <span aria-hidden="true">🤖</span>
      <span>Add a bot</span>
    </button>
    """
  end

  attr :private_id, :string, required: true

  defp share_link(assigns) do
    ~H"""
    <div class="share-link-group">
      <span id="share_link" class="share-link-url">{url(~p"/play/private/#{@private_id}")}</span>
      <button
        id="copy_button"
        type="button"
        class="share-link-copy"
        phx-hook="CopyShareLink"
        aria-label="Copy the invite link"
      >
        <svg
          class="copy-icon"
          aria-hidden="true"
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
          aria-hidden="true"
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
    """
  end

  def render(%{live_action: :private_game} = assigns) do
    ~H"""
    <div id="queue-root" class="queue-page">
      <h1 class="queue-title">Private Game</h1>
      <p class="queue-subtitle">Share this link with friends:</p>
      <div class="share-link-row">
        <.share_link private_id={@private_id} />
      </div>

      <.queue_cards queue={@queue} />

      <.queue_actions
        in_queue={@in_queue}
        active_game={@active_game}
        join_label="Join Private Game"
        leave_label="Leave"
        waiting_message="You are in the game lobby"
      />
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="tabs-container">
      <nav class="tabs" aria-label="Lobby type">
        <.link
          patch={~p"/play"}
          class={["tab", @tab == "public" && "active"]}
          aria-current={@tab == "public" && "page"}
        >
          Public Queue
        </.link>
        <.link
          patch={~p"/play?tab=private"}
          class={["tab", @tab == "private" && "active"]}
          aria-current={@tab == "private" && "page"}
        >
          Play a Friend
        </.link>
      </nav>

      <div :if={@tab == "public"} id="queue-root" class="queue-page">
        <h1 class="queue-title">Queue</h1>
        <p class="queue-subtitle">4 players, 2 teams</p>

        <.queue_cards queue={@queue} />

        <.queue_actions
          in_queue={@in_queue}
          active_game={@active_game}
          join_label="Join Queue"
          leave_label="Leave Queue"
          waiting_message="You are in the queue"
        />
      </div>

      <div :if={@tab == "private"} class="queue-page queue-page-private">
        <p class="queue-subtitle">Invite a friend with a private link:</p>
        <.active_game_card :if={@active_game} game={@active_game} />
        <button
          :if={!@active_game}
          id="create-private-button"
          type="button"
          phx-click="create_private"
          class="text-sm font-semibold leading-6 text-white rounded-lg bg-zinc-900 py-2 px-3 green-button"
        >
          Create Private Game
        </button>
      </div>
    </div>
    """
  end
end
