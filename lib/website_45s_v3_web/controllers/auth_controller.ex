defmodule Website45sV3Web.AuthController do
  use Website45sV3Web, :controller

  require Logger

  plug Ueberauth

  alias Website45sV3.Accounts
  alias Website45sV3Web.UserAuth

  def request(conn, _params), do: redirect(conn, to: "/")

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case Accounts.get_or_create_google_user(auth) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user)

      {:error, reason} ->
        conn
        |> put_flash(:error, failure_message(reason))
        |> redirect(to: ~p"/users/log_in")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    Logger.info("Google sign-in failed: #{inspect(failure.errors)}")

    conn
    |> put_flash(:error, "Authentication failed")
    |> redirect(to: ~p"/users/log_in")
  end

  defp failure_message(:unconfirmed_account) do
    "An account with this email exists but is not confirmed. " <>
      "Confirm it or reset its password first."
  end

  defp failure_message(:email_unverified) do
    "Google has not verified the email address on this account, so it cannot be used to sign in."
  end

  defp failure_message(:email_missing) do
    "Google did not share an email address for this account."
  end

  defp failure_message(:google_account_mismatch) do
    "This email is already linked to a different Google account."
  end

  defp failure_message(reason) do
    Logger.error("Google sign-in could not be completed: #{inspect(reason)}")
    "Authentication failed"
  end
end
