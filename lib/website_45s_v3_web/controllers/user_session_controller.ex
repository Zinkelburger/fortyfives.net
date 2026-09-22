defmodule Website45sV3Web.UserSessionController do
  use Website45sV3Web, :controller

  alias Website45sV3.Accounts
  alias Website45sV3.Security.RateLimiter
  alias Website45sV3.Turnstile
  alias Website45sV3Web.UserAuth

  def create(conn, params) do
    identifier = login_identifier(params)
    remote_ip = Turnstile.client_ip(conn)

    with :ok <- RateLimiter.check_login_ip(remote_ip),
         {:ok, conn, info, expected_user_id} <- authorize_login(conn, params, remote_ip) do
      authenticate(conn, params, identifier, info, expected_user_id)
    else
      {:error, :rate_limited} ->
        login_error(conn, identifier, "Too many login attempts. Please wait and try again.")

      {:error, :turnstile_failed} ->
        login_error(conn, identifier, "Please complete the verification challenge and try again.")

      {:error, :invalid_post_auth} ->
        login_error(conn, identifier, "That sign-in request expired. Please log in again.")
    end
  end

  # The per-account budget is enforced before the password is even checked:
  # while it is exhausted the account refuses everyone, correct password
  # included, until the window rolls over. Otherwise the message would be
  # decoration — a guesser could keep trying at full speed and only the
  # legitimate owner would ever see it. The lockout-as-DoS trade-off this
  # creates is discussed on `RateLimiter.login_account_exhausted?/1`; the
  # short fixed window in `:security_rate_limits` keeps it a nuisance at
  # worst, and the per-IP budget above still applies on top.
  defp authenticate(conn, params, identifier, info, expected_user_id) do
    account_key = login_account_key(identifier)

    if RateLimiter.login_account_exhausted?(account_key) do
      login_error(
        conn,
        identifier,
        "Too many failed attempts for this account. Please wait and try again."
      )
    else
      check_credentials(conn, params, identifier, info, expected_user_id, account_key)
    end
  end

  # Submitted automatically right after registration (see the registration
  # LiveView's `phx-trigger-action`), so a failure here means the account
  # exists but the browser could not be signed in to it.
  defp check_credentials(
         conn,
         %{"user" => %{"username" => username, "password" => password} = user_params},
         identifier,
         info,
         expected_user_id,
         account_key
       )
       when is_integer(expected_user_id) and is_binary(username) and is_binary(password) do
    user = Accounts.get_user_by_username_and_password(username, password)

    if authorized_user?(user, expected_user_id) do
      succeed(conn, user, user_params, info, account_key)
    else
      RateLimiter.record_login_failure(account_key)

      login_error(
        conn,
        identifier,
        "Your account was created, but we could not sign you in automatically. " <>
          "Please log in with your new password."
      )
    end
  end

  defp check_credentials(
         conn,
         %{"user" => %{"password" => password} = user_params},
         identifier,
         info,
         expected_user_id,
         account_key
       )
       when is_binary(identifier) and is_binary(password) do
    user = get_user_by_login_identifier(identifier, password)

    if authorized_user?(user, expected_user_id) do
      succeed(conn, user, user_params, info, account_key)
    else
      RateLimiter.record_login_failure(account_key)
      # In order to prevent user enumeration attacks, don't disclose whether
      # the account is registered.
      login_error(conn, identifier, invalid_credentials_message(identifier))
    end
  end

  # A request with no usable credentials at all — fields missing, or sent as
  # something other than strings (`user[password][]=…`). It never had an
  # account key, so there is nothing to charge and nothing to look up.
  defp check_credentials(conn, _params, identifier, _info, _expected_user_id, _account_key) do
    login_error(conn, identifier, invalid_credentials_message(identifier))
  end

  defp succeed(conn, user, user_params, info, account_key) do
    RateLimiter.reset_login_account(account_key)

    conn
    |> put_flash(:info, info)
    |> UserAuth.log_in_user(user, user_params)
  end

  defp authorize_login(conn, %{"_action" => action, "post_auth_token" => token}, _remote_ip)
       when action in ["registered", "password_updated"] and is_binary(token) do
    case Phoenix.Token.verify(Website45sV3Web.Endpoint, "post-auth", token, max_age: 120) do
      {:ok, {:registered, user_id}} when action == "registered" and is_integer(user_id) ->
        {:ok, conn, "Account created successfully!", user_id}

      {:ok, {:registered, user_id, :confirmation_email_failed}}
      when action == "registered" and is_integer(user_id) ->
        {:ok, conn, registered_without_email_message(), user_id}

      {:ok, {:password_updated, user_id}}
      when action == "password_updated" and is_integer(user_id) ->
        conn = put_session(conn, :user_return_to, ~p"/users/settings")
        {:ok, conn, "Password updated successfully!", user_id}

      _ ->
        {:error, :invalid_post_auth}
    end
  end

  defp authorize_login(_conn, %{"_action" => action}, _remote_ip)
       when action in ["registered", "password_updated"],
       do: {:error, :invalid_post_auth}

  defp authorize_login(conn, params, remote_ip) do
    case Turnstile.verify(params["cf-turnstile-response"], remote_ip) do
      :ok -> {:ok, conn, "Welcome back!", nil}
      error -> error
    end
  end

  defp registered_without_email_message do
    "Account created, but we could not send your confirmation email. " <>
      "You can request a new one from the Resend confirmation page (/users/confirm)."
  end

  defp authorized_user?(nil, _expected_user_id), do: false
  defp authorized_user?(_user, nil), do: true
  defp authorized_user?(user, expected_user_id), do: user.id == expected_user_id

  # The identifier the visitor typed, or nil when it is absent or not a
  # string (a repeated `[]` param arrives as a list).
  defp login_identifier(params) do
    Enum.find_value(["username_or_email", "username", "email"], fn key ->
      case get_in(params, ["user", key]) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp login_account_key(identifier) when is_binary(identifier) do
    user =
      if String.contains?(identifier, "@") do
        Accounts.get_user_by_email(identifier)
      else
        Accounts.get_user_by_username(identifier)
      end

    if user, do: {:user, user.id}, else: {:identifier, String.downcase(String.trim(identifier))}
  end

  defp login_account_key(_identifier), do: nil

  defp invalid_credentials_message(identifier) when is_binary(identifier) do
    if String.contains?(identifier, "@"),
      do: "Invalid email or password",
      else: "Invalid username or password"
  end

  defp invalid_credentials_message(_identifier), do: "Invalid username or password"

  defp login_error(conn, identifier, message) do
    conn
    |> put_flash(:error, message)
    |> put_flash(:username_or_email, String.slice(identifier || "", 0, 160))
    |> redirect(to: ~p"/users/log_in")
  end

  defp get_user_by_login_identifier(username_or_email, password) do
    if String.contains?(username_or_email, "@") do
      Accounts.get_user_by_email_and_password(username_or_email, password)
    else
      Accounts.get_user_by_username_and_password(username_or_email, password)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
