defmodule Website45sV3Web.AuthController do
  use Website45sV3Web, :controller

  plug Ueberauth

  alias Website45sV3.Accounts
  alias Website45sV3Web.UserAuth

  def request(conn, _params), do: redirect(conn, to: "/")

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case Accounts.get_or_create_google_user(auth) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user)
      {:error, _reason} ->
        conn
        |> put_flash(:error, "Authentication failed")
        |> redirect(to: ~p"/users/log_in")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _fails}} = conn, _params) do
    conn
    |> put_flash(:error, "Authentication failed")
    |> redirect(to: ~p"/users/log_in")
  end
end
