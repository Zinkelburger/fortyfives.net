defmodule Website45sV3Web.SlotRouting do
  @moduledoc """
  The app's side of blue/green routing (see `Website45sV3.Slot`).

  As a plug in the `:browser` pipeline it sets the `ff_slot` cookie to the
  slot that served the page. nginx only reads that cookie for a slot that
  is draining, so it pins a browser to the old slot while the deploy lets
  its games finish. A draining slot keeps a request only from a player
  seated in one of its games; anyone else gets the cookie cleared and is
  sent back to the same URL, which nginx then hands to the live slot.

  As an `on_mount` hook it reloads a LiveView when its slot starts to
  drain, unless the player is seated in a game there. `QueueLive` handles
  the message itself, so the reload can carry the player's seat in the
  queue or lobby.
  """
  import Plug.Conn

  alias Website45sV3.Slot

  @cookie "ff_slot"
  @cookie_options [
    max_age: 24 * 60 * 60,
    http_only: true,
    same_site: "Lax",
    secure: Application.compile_env(:website_45s_v3, :secure_cookies, false)
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    case Slot.name() do
      nil -> conn
      slot -> route(fetch_cookies(conn), slot)
    end
  end

  defp route(conn, slot) do
    cond do
      not Slot.draining?() or Slot.seated_here?(get_session(conn, :user_id)) ->
        put_resp_cookie(conn, @cookie, slot, @cookie_options)

      # Sent here because of the cookie: clear it and go again.
      conn.cookies[@cookie] == slot and conn.method == "GET" ->
        conn
        |> delete_resp_cookie(@cookie, Keyword.delete(@cookie_options, :max_age))
        |> put_resp_header("cache-control", "no-store")
        |> Phoenix.Controller.redirect(to: current_path(conn))
        |> halt()

      # Sent here without the cookie: nginx still names this slot live, or
      # an nginx worker from before the switch took the request. Serve it,
      # but do not pin the browser here; the page's LiveView connects with a
      # new request, which goes to the live slot.
      true ->
        conn
    end
  end

  defp current_path(%{query_string: ""} = conn), do: conn.request_path
  defp current_path(conn), do: conn.request_path <> "?" <> conn.query_string

  @doc false
  def on_mount(:default, _params, session, socket) do
    if Slot.name() && Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, Slot.topic())
      user_id = session["user_id"]

      {:cont,
       Phoenix.LiveView.attach_hook(socket, :slot_routing, :handle_info, fn
         :slot_draining, socket -> on_drain(socket, user_id)
         _msg, socket -> {:cont, socket}
       end)}
    else
      {:cont, socket}
    end
  end

  defp on_drain(%{view: Website45sV3Web.QueueLive} = socket, _user_id), do: {:cont, socket}

  defp on_drain(socket, user_id) do
    if Slot.seated_here?(user_id) do
      {:halt, socket}
    else
      {:halt, reload(socket)}
    end
  end

  @doc """
  Reloads the page (or loads `to`). The request reaches this slot again
  with the cookie, and the plug above sends it on to the live slot.
  """
  def reload(socket, to \\ nil) do
    Phoenix.LiveView.push_event(socket, "ff-reload", if(to, do: %{to: to}, else: %{}))
  end
end
