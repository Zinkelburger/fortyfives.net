defmodule Website45sV3Web.SessionController do
  use Website45sV3Web, :controller
  alias UUID

  def update(conn, %{"user_id" => user_id}) do
    conn
    |> put_session(:user_id, user_id)
    |> send_resp(200, "Session updated")
  end

  def get_user_id(conn, _params) do
    current_user = get_session(conn, :current_user)

    case current_user do
      %{"username" => username} ->
        # If the user is logged in with a username, return the formatted user ID
        user_id = "user_#{username}"
        conn |> json(%{user_id: user_id})
      nil ->
        # If there is no logged-in user, check for an existing anonymous user ID
        case get_session(conn, :user_id) do
          nil ->
            # Generate an anonymous ID if none exists
            user_id = "anon_#{UUID.uuid4()}"
            updated_conn = put_session(conn, :user_id, user_id)
            updated_conn |> json(%{user_id: user_id})
          existing_user_id ->
            # Return existing anonymous user ID
            conn |> json(%{user_id: existing_user_id})
        end
    end
  end
end
