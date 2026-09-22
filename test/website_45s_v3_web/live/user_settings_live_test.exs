defmodule Website45sV3Web.UserSettingsLiveTest do
  use Website45sV3Web.ConnCase

  alias Website45sV3.Accounts
  alias Website45sV3.Security.RateLimiter
  import Phoenix.LiveViewTest
  import Website45sV3.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
      assert html =~ "Change Password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log_in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "update username form" do
    setup %{conn: conn} do
      RateLimiter.reset()
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "changes the username without asking for a password", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      new_name = "renamed_#{System.unique_integer([:positive])}"

      result =
        lv
        |> form("#username_form", %{"user" => %{"username" => new_name}})
        |> render_submit()

      assert result =~ "Username changed to #{new_name}"
      assert Accounts.get_user!(user.id).username == new_name
    end

    test "refuses a name that is taken, banned or unchanged", %{conn: conn, user: user} do
      other = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      for {name, error} <- [
            {other.username, "has already been taken"},
            {"admin", "Contains a banned word"},
            {user.username, "did not change"}
          ] do
        result =
          lv
          |> form("#username_form", %{"user" => %{"username" => name}})
          |> render_submit()

        assert result =~ error
      end

      assert Accounts.get_user!(user.id).username == user.username
    end

    test "caps how often the username can change", %{conn: conn, user: user} do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)
      Application.put_env(:website_45s_v3, :security_rate_limits, username: [max_account: 1])
      on_exit(fn -> Application.put_env(:website_45s_v3, :security_rate_limits, previous) end)

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv
      |> form("#username_form", %{"user" => %{"username" => "first_#{user.id}"}})
      |> render_submit()

      result =
        lv
        |> form("#username_form", %{"user" => %{"username" => "second_#{user.id}"}})
        |> render_submit()

      assert result =~ "changed your username too often"
      assert Accounts.get_user!(user.id).username == "first_#{user.id}"
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      RateLimiter.reset()
      password = valid_user_password()
      user = user_fixture(%{password: password})
      %{conn: log_in_user(conn, user), user: user, password: password}
    end

    test "caps how many email changes one account can request",
         %{conn: conn, password: password} do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)
      Application.put_env(:website_45s_v3, :security_rate_limits, email: [max_account: 1])
      on_exit(fn -> Application.put_env(:website_45s_v3, :security_rate_limits, previous) end)

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      submit = fn ->
        lv
        |> form("#email_form", %{
          "current_password" => password,
          "user" => %{"email" => unique_user_email()}
        })
        |> render_submit()
      end

      assert submit.() =~ "A link to confirm your email"
      assert submit.() =~ "Too many email change requests"
    end

    test "updates the user email", %{conn: conn, password: password, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "current_password" => password,
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "current_password" => "invalid",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "Must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "current_password" => "invalid",
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "Did not change"
      assert result =~ "Is not valid"
    end

    test "never echoes the current password back into the page", %{conn: conn, password: password} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{"current_password" => password, "user" => %{"email" => "x"}})

      refute result =~ password

      result =
        lv
        |> form("#email_form", %{"current_password" => password, "user" => %{"email" => "x"}})
        |> render_submit()

      refute result =~ password
    end

    test "tells the user when the confirmation email cannot be sent",
         %{conn: conn, password: password, user: user} do
      Website45sV3.FailingMailAdapter.enable()
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "current_password" => password,
          "user" => %{"email" => unique_user_email()}
        })
        |> render_submit()

      assert result =~ "could not send a confirmation link"
      refute result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      password = valid_user_password()
      user = user_fixture(%{password: password})
      %{conn: log_in_user(conn, user), user: user, password: password}
    end

    test "updates the user password", %{conn: conn, user: user, password: password} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "current_password" => password,
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "signs out the user's other open sessions but not this one",
         %{conn: conn, user: user, password: password} do
      other_token = Accounts.generate_user_session_token(user)
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, Accounts.live_socket_id(other_token))
      this_token = get_session(conn, :user_token)
      Phoenix.PubSub.subscribe(Website45sV3.PubSub, Accounts.live_socket_id(this_token))

      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      new_password = valid_user_password() <> "!"

      lv
      |> form("#password_form", %{
        "current_password" => password,
        "user" => %{"password" => new_password, "password_confirmation" => new_password}
      })
      |> render_submit()

      other_topic = Accounts.live_socket_id(other_token)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}

      this_topic = Accounts.live_socket_id(this_token)
      refute_received %Phoenix.Socket.Broadcast{topic: ^this_topic}
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "current_password" => "invalid",
          "user" => %{
            "password" => "short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Change Password"
      assert result =~ "should be at least 8 character(s)"
      assert result =~ "Does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "current_password" => "invalid",
          "user" => %{
            "password" => "short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Change Password"
      assert result =~ "should be at least 8 character(s)"
      assert result =~ "Does not match password"
      assert result =~ "Is not valid"
    end

    test "never echoes typed passwords back into the page", %{conn: conn, password: password} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "current_password" => password,
          "user" => %{"password" => "brand new secret", "password_confirmation" => "brand new"}
        })

      refute result =~ password
      refute result =~ "brand new secret"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm_email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm_email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm_email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm_email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log_in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
