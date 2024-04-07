defmodule Website45sV3Web.SessionController do
  use Website45sV3Web, :controller
  alias UUID

  def update(conn, %{"user_id" => user_id}) do
    conn
    |> put_session(:user_id, user_id)
    |> send_resp(200, "Session updated")
  end

  def get_user_id(conn, _params) do
    # Check if the user_id is already set in the session
    case get_session(conn, :user_id) do
      nil ->
        # If user_id is not set, generate a new one and update the session
        user_id = "anon_#{UUID.uuid4()}"
        updated_conn = put_session(conn, :user_id, user_id)
        updated_conn |> json(%{user_id: user_id})
      existing_user_id ->
        # If user_id is already set, return the existing user_id
        conn |> json(%{user_id: existing_user_id})
    end
  end
end
