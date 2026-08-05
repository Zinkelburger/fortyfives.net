defmodule Website45sV3Web.UserSessionController do
  use Website45sV3Web, :controller

  alias Website45sV3.Accounts
  alias Website45sV3.Turnstile
  alias Website45sV3Web.UserAuth

  # The Turnstile token for these two actions was already verified (and
  # consumed) by the LiveView that triggered the follow-up log-in POST, so
  # they are not re-checked here.
  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created successfully!")
  end

  def create(conn, %{"_action" => "password_updated"} = params) do
    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def create(conn, params) do
    case Turnstile.verify(params["cf-turnstile-response"], Turnstile.client_ip(conn)) do
      :ok ->
        create(conn, params, "Welcome back!")

      {:error, :turnstile_failed} ->
        username_or_email = get_in(params, ["user", "username_or_email"]) || ""

        conn
        |> put_flash(:error, "Please complete the verification challenge and try again.")
        |> put_flash(:username_or_email, String.slice(username_or_email, 0, 160))
        |> redirect(to: ~p"/users/log_in")
    end
  end

  defp create(
         conn,
         %{
           "user" =>
             %{"username" => username, "email" => _email, "password" => password} = user_params
         },
         info
       ) do
    user = Accounts.get_user_by_username_and_password(username, password)

    if user do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      conn
      |> put_flash(:error, "Something went wrong during registration. Please try again.")
      |> redirect(to: ~p"/users/register")
    end
  end

  defp create(conn, %{"user" => user_params}, info) do
    username_or_email = Map.get(user_params, "username_or_email") || Map.get(user_params, "email")
    password = Map.get(user_params, "password")

    user = get_user_by_login_identifier(username_or_email, password)

    if user do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:username_or_email, String.slice(username_or_email || "", 0, 160))
      |> redirect(to: ~p"/users/log_in")
    end
  end

  defp get_user_by_login_identifier(username_or_email, password)
       when is_binary(username_or_email) and is_binary(password) do
    if String.contains?(username_or_email, "@") do
      Accounts.get_user_by_email_and_password(username_or_email, password)
    else
      Accounts.get_user_by_username_and_password(username_or_email, password)
    end
  end

  defp get_user_by_login_identifier(_, _), do: nil

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
