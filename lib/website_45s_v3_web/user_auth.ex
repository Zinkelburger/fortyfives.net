defmodule Website45sV3Web.UserAuth do
  @moduledoc """
  Session handling for the web layer: logging users in and out, the plugs
  that load `current_user` for controllers, and the `on_mount` hooks that do
  the same for LiveViews.

  Every browser session also carries an *anonymous player id* under the
  `:user_id` session key. It is not a credential — it is the seat identity the
  queue and game processes key on, for signed-in and anonymous visitors alike
  — so it is minted once per browser and deliberately survives logging in
  and out, which would otherwise pull a player out of a game in progress.
  """

  use Website45sV3Web, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Website45sV3.Accounts

  # Make the remember me cookie valid for 60 days.
  # If you want bump or reduce this value, also change
  # the token expiry itself in UserToken.
  @max_age 60 * 60 * 24 * 60
  @remember_me_cookie "_website45s_v3_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_age,
    same_site: "Lax",
    secure: Application.compile_env(:website_45s_v3, :secure_cookies, false),
    http_only: true
  ]

  @doc """
  Logs the user in.

  It renews the session ID and clears the whole session
  to avoid fixation attacks. See the renew_session
  function to customize this behaviour.

  It also sets a `:live_socket_id` key in the session,
  so LiveView sessions are identified and automatically
  disconnected on log out. The line can be safely removed
  if you are not using LiveView.
  """
  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}) do
    put_resp_cookie(conn, @remember_me_cookie, token, @remember_me_options)
  end

  defp maybe_write_remember_me_cookie(conn, _token, _params) do
    conn
  end

  # Renews the session ID and erases the whole session to avoid fixation
  # attacks. The anonymous player id is the one value carried across: it is
  # a seat identity, not a credential (see the module docs), and dropping it
  # would eject the player from any game or queue they are in.
  defp renew_session(conn) do
    player_id = get_session(conn, :user_id)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_player_id(player_id)
  end

  defp put_player_id(conn, nil), do: conn
  defp put_player_id(conn, player_id), do: put_session(conn, :user_id, player_id)

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      Website45sV3Web.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> delete_resp_cookie(@remember_me_cookie)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token,
  assigning `:current_user` (or `nil`), and ensures the request has an
  anonymous player id, assigned as `:user_id` and stored in the session.

  One plug, one lookup: every browser request needs both values, and doing
  them in separate plugs used to authenticate each request twice.
  """
  def fetch_current_user(conn, _opts) do
    {user_token, conn} = ensure_user_token(conn)
    user = user_token && Accounts.get_user_by_session_token(user_token)

    conn
    |> assign(:current_user, user)
    |> ensure_player_id()
  end

  defp ensure_player_id(conn) do
    case get_session(conn, :user_id) do
      nil ->
        player_id = Ecto.UUID.generate()

        conn
        |> put_session(:user_id, player_id)
        |> assign(:user_id, player_id)

      player_id ->
        assign(conn, :user_id, player_id)
    end
  end

  def assign_canonical_path(conn, _opts) do
    assign(conn, :canonical_path, conn.request_path)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, put_token_in_session(conn, token)}
      else
        {nil, conn}
      end
    end
  end

  @doc """
  Handles mounting and authenticating the current_user in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_user` - Assigns current_user
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user. Also assigns
      `:user_id`, the anonymous player id from the session.

    * `:ensure_authenticated` - Authenticates the user from the session,
      and assigns the current_user to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

    * `:redirect_if_user_is_authenticated` - Authenticates the user from the session.
      Redirects to signed_in_path if there's a logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the current_user:

      defmodule Website45sV3Web.PageLive do
        use Website45sV3Web, :live_view

        on_mount {Website45sV3Web.UserAuth, :mount_current_user}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{Website45sV3Web.UserAuth, :ensure_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    socket =
      socket
      |> mount_current_user(session)
      |> mount_player_id(session)
      |> attach_request_path_hook()

    {:cont, socket}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      socket = attach_request_path_hook(socket)

      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log_in")

      {:halt, socket}
    end
  end

  def on_mount(:redirect_if_user_is_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, attach_request_path_hook(socket)}
    end
  end

  # A socket without a router (e.g. one built directly in tests) cannot have
  # a :handle_params hook attached.
  defp attach_request_path_hook(%Phoenix.LiveView.Socket{router: nil} = socket), do: socket

  defp attach_request_path_hook(socket) do
    Phoenix.LiveView.attach_hook(socket, :save_request_path, :handle_params, fn
      _params, uri, socket ->
        {:cont, assign_request_path(socket, uri)}
    end)
  end

  defp assign_request_path(socket, uri) do
    path = URI.parse(uri).path

    socket
    |> Phoenix.Component.assign(:current_uri, path)
    |> Phoenix.Component.assign(:canonical_path, path)
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if user_token = session["user_token"] do
        Accounts.get_user_by_session_token(user_token)
      end
    end)
  end

  defp mount_player_id(socket, session) do
    Phoenix.Component.assign_new(socket, :user_id, fn -> session["user_id"] end)
  end

  @doc """
  Used for routes that require the user to not be authenticated.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc """
  Used for routes that require the user to be authenticated.

  If you want to enforce the user email is confirmed before
  they use the application at all, here would be a good place.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end

  @doc """
  Whether the user may see `/admin`: their id is in the
  `:admin_user_ids` config (ADMIN_USER_IDS in the environment).
  """
  def admin?(%{id: id}) when is_integer(id) do
    id in Application.get_env(:website_45s_v3, :admin_user_ids, [])
  end

  def admin?(_user), do: false

  @doc """
  Used for routes that require an admin. Non-admins (logged in or not) are
  sent home; the section is not advertised to them.
  """
  def require_admin(conn, _opts) do
    if admin?(conn.assigns[:current_user]) do
      # The root layout loads the replay player bundle for admin pages only.
      assign(conn, :admin_assets, true)
    else
      conn
      |> put_flash(:error, "Page not found.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, Accounts.live_socket_id(token))
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp signed_in_path(_conn), do: ~p"/"
end
