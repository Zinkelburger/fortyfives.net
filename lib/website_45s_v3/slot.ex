defmodule Website45sV3.Slot do
  @moduledoc """
  Blue/green deploys. Production runs two copies of the app, `web_blue` and
  `web_green`, behind one nginx; each knows its name from `FF_SLOT`. A
  deploy starts the new image in the idle slot, points nginx at it, and
  tells the old slot to drain (`drain/0`, called by
  `deploy/contabo/slots.sh` over `bin/website_45s_v3 rpc`):

    * games keep running on the old slot. nginx sends a browser back to the
      slot named in its `ff_slot` cookie while that slot drains, and every
      page the old slot serves to a seated player renews the cookie
      (`Website45sV3Web.SlotRouting`);
    * every other open page reloads and lands on the new slot. Players in
      the public queue or a private lobby carry a signed handoff
      (`handoff_token/1`) that seats them, and the bots they added, again
      on the new slot;
    * once the old slot has no games left, the deploy stops it.

  Both slots share the SQLite database and `SECRET_KEY_BASE`, so sessions
  and the tokens here are valid on either.

  Outside production `FF_SLOT` is unset, `name/0` is nil and nothing here
  changes how the app behaves.
  """
  require Logger

  alias Website45sV3.Game.ActiveGames
  alias Website45sV3.Game.BotSupervisor
  alias Website45sV3.Game.GameSupervisor
  alias Website45sV3.Game.QueueStarter

  @topic "slot"
  @draining {__MODULE__, :draining}
  @handoff_salt "slot handoff"
  @handoff_max_age 15 * 60
  @rematch_salt "slot rematch"
  @rematch_max_age 2 * 60 * 60

  @doc ~s(This copy's slot, "blue" or "green"; nil outside production.)
  def name, do: Application.get_env(:website_45s_v3, :slot)

  @doc "PubSub topic every LiveView hears `:slot_draining` on."
  def topic, do: @topic

  def draining?, do: :persistent_term.get(@draining, false)

  @doc """
  Hands everything but the running games to the other slot. Idempotent;
  returns the same line as `status/0`.
  """
  def drain do
    unless draining?() do
      :persistent_term.put(@draining, true)
      Logger.info("Slot #{name()}: draining (#{status()})")
    end

    Phoenix.PubSub.broadcast(Website45sV3.PubSub, @topic, :slot_draining)

    # Queued bots would only hold seats nobody can reach any more. The pages
    # count the bots their player added into the handoff first, and the
    # other slot seats new ones.
    Task.start(fn ->
      Process.sleep(10_000)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(BotSupervisor), is_pid(pid) do
        send(pid, :queue_closed)
      end
    end)

    status()
  end

  @doc "Takes this slot back after a drain (a rollback that flips back to it)."
  def undrain do
    if draining?() do
      :persistent_term.erase(@draining)
      Logger.info("Slot #{name()}: taking traffic again")
    end

    status()
  end

  @doc """
  `"<games> <queued> <draining|live>"`: running games, players in the public
  queue, and whether this slot drains. What `slots.sh` waits on.
  """
  def status do
    games = DynamicSupervisor.count_children(GameSupervisor).active
    state = if draining?(), do: "draining", else: "live"
    "#{games} #{QueueStarter.player_count()} #{state}"
  end

  @doc "Whether `user_id` has a game on this slot (and so must stay here)."
  def seated_here?(user_id) when is_binary(user_id), do: ActiveGames.find_game(user_id) != nil
  def seated_here?(_user_id), do: false

  @doc """
  Signs where a player was in the lobby: `%{user: id, lobby: nil | id,
  owner: id, join: boolean, bots: count}`. The other slot reads it with
  `verify_handoff/2` when the reloaded page arrives there.
  """
  def handoff_token(%{user: _, lobby: _, join: _, bots: _} = handoff) do
    Phoenix.Token.sign(Website45sV3Web.Endpoint, @handoff_salt, handoff)
  end

  @doc "The handoff in `token` if it is valid and was made for `user_id`."
  def verify_handoff(token, user_id) when is_binary(token) do
    case Phoenix.Token.verify(Website45sV3Web.Endpoint, @handoff_salt, token,
           max_age: @handoff_max_age
         ) do
      {:ok, %{user: ^user_id} = handoff} -> {:ok, handoff}
      _ -> :error
    end
  end

  def verify_handoff(_token, _user_id), do: :error

  @doc """
  A finished private game offers its players a lobby for another game. On
  a draining slot that lobby must open on the other slot, which has never
  heard of it; this token lets it.
  """
  def rematch_token(lobby_id),
    do: Phoenix.Token.sign(Website45sV3Web.Endpoint, @rematch_salt, lobby_id)

  def verify_rematch(token, lobby_id) when is_binary(token) do
    case Phoenix.Token.verify(Website45sV3Web.Endpoint, @rematch_salt, token,
           max_age: @rematch_max_age
         ) do
      {:ok, ^lobby_id} -> :ok
      _ -> :error
    end
  end

  def verify_rematch(_token, _lobby_id), do: :error
end
