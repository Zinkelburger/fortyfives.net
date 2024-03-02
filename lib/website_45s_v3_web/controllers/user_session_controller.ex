defmodule Website45sV3Web.UserSessionController do
  use Website45sV3Web, :controller

  alias Website45sV3.Accounts
  alias Website45sV3Web.UserAuth

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created successfully!")
  end

  def create(conn, %{"_action" => "password_updated"} = params) do
    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
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
    %{"username_or_email" => username_or_email, "password" => password} = user_params

    user =
      if String.contains?(username_or_email, "@") do
        Accounts.get_user_by_email_and_password(username_or_email, password)
      else
        Accounts.get_user_by_username_and_password(username_or_email, password)
      end

    if user do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:username_or_email, String.slice("username_or_email", 0, 160))
      |> redirect(to: ~p"/users/log_in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
