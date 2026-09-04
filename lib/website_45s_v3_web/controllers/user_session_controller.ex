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
      authenticate(conn, params, info, expected_user_id, login_account_key(identifier))
    else
      {:error, :rate_limited} ->
        login_error(conn, identifier, "Too many login attempts. Please wait and try again.")

      {:error, :turnstile_failed} ->
        login_error(conn, identifier, "Please complete the verification challenge and try again.")

      {:error, :invalid_post_auth} ->
        login_error(conn, identifier, "That sign-in request expired. Please log in again.")
    end
  end

  defp authenticate(
         conn,
         %{
           "user" =>
             %{"username" => username, "email" => _email, "password" => password} = user_params
         },
         info,
         expected_user_id,
         account_key
       ) do
    user = Accounts.get_user_by_username_and_password(username, password)

    if authorized_user?(user, expected_user_id) do
      succeed(conn, user, user_params, info, account_key)
    else
      fail(conn, account_key, username, fn conn ->
        conn
        |> put_flash(:error, "Something went wrong during registration. Please try again.")
        |> redirect(to: ~p"/users/register")
      end)
    end
  end

  defp authenticate(conn, %{"user" => user_params}, info, expected_user_id, account_key) do
    username_or_email = Map.get(user_params, "username_or_email") || Map.get(user_params, "email")
    password = Map.get(user_params, "password")

    user = get_user_by_login_identifier(username_or_email, password)

    if authorized_user?(user, expected_user_id) do
      succeed(conn, user, user_params, info, account_key)
    else
      fail(conn, account_key, username_or_email, fn conn ->
        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        login_error(conn, username_or_email, "Invalid email or password")
      end)
    end
  end

  # A request with no usable credentials at all. It never had an account key,
  # so there is nothing to charge — and reporting it as rate limiting (which
  # is what the nil key used to produce) hid real throttling behind a
  # misleading message.
  defp authenticate(conn, _params, _info, _expected_user_id, _account_key) do
    login_error(conn, "", "Invalid email or password")
  end

  defp succeed(conn, user, user_params, info, account_key) do
    RateLimiter.reset_login_account(account_key)

    conn
    |> put_flash(:info, info)
    |> UserAuth.log_in_user(user, user_params)
  end

  # The per-account budget throttles *failed* guesses only, and is consulted
  # only once a guess has already turned out to be wrong. Refusing a request
  # up front because the account is over budget would let anyone who knows a
  # username lock its owner out at will, indefinitely, by burning the budget
  # once per window. A guesser gains nothing from the softer rule: their wrong
  # password is rejected either way.
  defp fail(conn, account_key, identifier, on_invalid) do
    exhausted? = RateLimiter.login_account_exhausted?(account_key)
    RateLimiter.record_login_failure(account_key)

    if exhausted? do
      login_error(
        conn,
        identifier,
        "Too many failed attempts for this account. Please wait and try again."
      )
    else
      on_invalid.(conn)
    end
  end

  defp authorize_login(conn, %{"_action" => action, "post_auth_token" => token}, _remote_ip)
       when action in ["registered", "password_updated"] and is_binary(token) do
    expected_purpose =
      case action do
        "registered" -> :registered
        "password_updated" -> :password_updated
      end

    case Phoenix.Token.verify(Website45sV3Web.Endpoint, "post-auth", token, max_age: 120) do
      {:ok, {^expected_purpose, user_id}} when is_integer(user_id) ->
        info =
          if action == "registered",
            do: "Account created successfully!",
            else: "Password updated successfully!"

        conn =
          if action == "password_updated",
            do: put_session(conn, :user_return_to, ~p"/users/settings"),
            else: conn

        {:ok, conn, info, user_id}

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

  defp authorized_user?(nil, _expected_user_id), do: false
  defp authorized_user?(_user, nil), do: true
  defp authorized_user?(user, expected_user_id), do: user.id == expected_user_id

  defp login_identifier(params) do
    get_in(params, ["user", "username_or_email"]) ||
      get_in(params, ["user", "username"]) ||
      get_in(params, ["user", "email"])
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

  defp login_error(conn, identifier, message) do
    conn
    |> put_flash(:error, message)
    |> put_flash(:username_or_email, String.slice(identifier || "", 0, 160))
    |> redirect(to: ~p"/users/log_in")
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
