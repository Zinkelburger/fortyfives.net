defmodule Website45sV3Web.UserSessionControllerTest do
  use Website45sV3Web.ConnCase, async: false

  import Website45sV3.AccountsFixtures
  alias Website45sV3.Security.RateLimiter

  setup do
    :ok = RateLimiter.reset()
    %{user: user_fixture()}
  end

  describe "POST /users/log_in" do
    test "logs the user in", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username_or_email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log_out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{
            "username_or_email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_website45s_v3_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log_in", %{
          "user" => %{
            "username_or_email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "login following registration", %{conn: conn, user: user} do
      conn =
        conn
        |> post(~p"/users/log_in", %{
          "_action" => "registered",
          "post_auth_token" => post_auth_token(:registered, user),
          "user" => %{
            "username" => user.username,
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully"
    end

    test "login following password update", %{conn: conn, user: user} do
      conn =
        conn
        |> post(~p"/users/log_in", %{
          "_action" => "password_updated",
          "post_auth_token" => post_auth_token(:password_updated, user),
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password updated successfully"
    end

    test "redirects to login page with invalid credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{
            "username_or_email" => "invalid@email.com",
            "password" => "invalid_password"
          }
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log_in"
    end

    test "rejects a client-selected post-authentication bypass", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "_action" => "registered",
          "user" => %{
            "username" => user.username,
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "rate limits repeated attempts for one account", %{conn: conn, user: user} do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)

      Application.put_env(:website_45s_v3, :security_rate_limits,
        login: [window_ms: 60_000, max_ip: 100, max_account: 1],
        queue: [window_ms: 60_000, max_ip: 100, max_create_ip: 100]
      )

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous)
        RateLimiter.reset()
      end)

      params = %{
        "user" => %{"username_or_email" => user.email, "password" => "wrong password"}
      }

      _first = post(conn, ~p"/users/log_in", params)
      second = post(conn, ~p"/users/log_in", params)

      assert Phoenix.Flash.get(second.assigns.flash, :error) =~ "Too many failed attempts"
    end

    test "a spent account budget refuses even the real password until the window passes",
         %{conn: conn, user: user} do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)

      # A 300ms window keeps the rollover observable in a test.
      Application.put_env(:website_45s_v3, :security_rate_limits,
        login: [window_ms: 300, max_ip: 100, max_account: 1],
        queue: [window_ms: 60_000, max_ip: 100, max_create_ip: 100]
      )

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous)
        RateLimiter.reset()
      end)

      post(conn, ~p"/users/log_in", %{
        "user" => %{"username_or_email" => user.email, "password" => "wrong password"}
      })

      assert RateLimiter.login_account_exhausted?({:user, user.id})

      # The message is enforced, not decorative: a correct password is refused
      # too while the budget is spent.
      refused =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username_or_email" => user.email, "password" => valid_user_password()}
        })

      refute get_session(refused, :user_token)
      assert redirected_to(refused) == ~p"/users/log_in"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "Too many failed attempts"

      # ...and honoured again once the window rolls over.
      Process.sleep(350)

      admitted =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username_or_email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(admitted, :user_token)
      assert redirected_to(admitted) == ~p"/"
      refute RateLimiter.login_account_exhausted?({:user, user.id})
    end

    test "the account budget is keyed on the account, whichever identifier is used",
         %{conn: conn, user: user} do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)

      Application.put_env(:website_45s_v3, :security_rate_limits,
        login: [window_ms: 60_000, max_ip: 100, max_account: 1],
        queue: [window_ms: 60_000, max_ip: 100, max_create_ip: 100]
      )

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous)
        RateLimiter.reset()
      end)

      post(conn, ~p"/users/log_in", %{
        "user" => %{"username_or_email" => user.email, "password" => "wrong password"}
      })

      by_username =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username_or_email" => user.username, "password" => valid_user_password()}
        })

      refute get_session(by_username, :user_token)
      assert Phoenix.Flash.get(by_username.assigns.flash, :error) =~ "Too many failed attempts"
    end

    test "refuses every attempt once the network budget is spent", %{conn: conn, user: user} do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)

      Application.put_env(:website_45s_v3, :security_rate_limits,
        login: [window_ms: 60_000, max_ip: 2, max_account: 100],
        queue: [window_ms: 60_000, max_ip: 100, max_create_ip: 100]
      )

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous)
        RateLimiter.reset()
      end)

      wrong = %{"user" => %{"username_or_email" => user.email, "password" => "wrong password"}}

      right = %{
        "user" => %{"username_or_email" => user.email, "password" => valid_user_password()}
      }

      post(conn, ~p"/users/log_in", wrong)
      post(conn, ~p"/users/log_in", wrong)

      refused = post(conn, ~p"/users/log_in", right)
      refute get_session(refused, :user_token)
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "Too many login attempts"
      assert redirected_to(refused) == ~p"/users/log_in"

      # Another network is unaffected.
      other = %{conn | remote_ip: {203, 0, 113, 77}}
      admitted = post(other, ~p"/users/log_in", right)
      assert get_session(admitted, :user_token)
    end

    test "fails closed when the client IP cannot be determined", %{conn: conn, user: user} do
      # The test adapter substitutes loopback for a nil peer, so the action is
      # invoked directly with the conn a peer-less transport would produce.
      refused =
        conn
        |> init_test_session(%{})
        |> fetch_flash()
        |> Map.put(:remote_ip, nil)
        |> Website45sV3Web.UserSessionController.create(%{
          "user" => %{"username_or_email" => user.email, "password" => valid_user_password()}
        })

      refute get_session(refused, :user_token)
      assert redirected_to(refused) == ~p"/users/log_in"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "Too many login attempts"
    end

    test "a failed challenge does not consume another account's failure budget", %{
      conn: conn,
      user: user
    } do
      previous_limits = Application.get_env(:website_45s_v3, :security_rate_limits)
      previous_site_key = Application.get_env(:website_45s_v3, :turnstile_site_key)
      previous_secret = Application.get_env(:website_45s_v3, :turnstile_secret)

      Application.put_env(:website_45s_v3, :security_rate_limits,
        login: [window_ms: 60_000, max_ip: 100, max_account: 1],
        queue: [window_ms: 60_000, max_ip: 100, max_create_ip: 100]
      )

      Application.put_env(:website_45s_v3, :turnstile_site_key, "configured")
      Application.delete_env(:website_45s_v3, :turnstile_secret)

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous_limits)
        Application.put_env(:website_45s_v3, :turnstile_site_key, previous_site_key)
        Application.put_env(:website_45s_v3, :turnstile_secret, previous_secret)
        RateLimiter.reset()
      end)

      params = %{
        "user" => %{
          "username_or_email" => user.email,
          "password" => valid_user_password()
        }
      }

      first = post(conn, ~p"/users/log_in", params)
      second = post(conn, ~p"/users/log_in", params)

      assert Phoenix.Flash.get(first.assigns.flash, :error) =~ "verification challenge"
      assert Phoenix.Flash.get(second.assigns.flash, :error) =~ "verification challenge"

      Application.put_env(:website_45s_v3, :turnstile_site_key, nil)
      successful = post(conn, ~p"/users/log_in", params)

      assert get_session(successful, :user_token)
      assert redirected_to(successful) == ~p"/"
    end
  end

  describe "POST /users/log_in with malformed or odd input" do
    test "a list where a string is expected is an ordinary failure, not a crash",
         %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username_or_email" => ["a", "b"], "password" => "whatever"}
        })

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"

      conn =
        post(build_conn(), ~p"/users/log_in", %{
          "user" => %{"username_or_email" => user.email, "password" => ["x"]}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
    end

    test "no credentials at all is an ordinary failure", %{conn: conn} do
      conn = post(conn, ~p"/users/log_in", %{"user" => %{}})
      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"

      conn = post(build_conn(), ~p"/users/log_in", %{})
      assert redirected_to(conn) == ~p"/users/log_in"
    end

    test "the wrong-credentials message names what the visitor typed", %{conn: conn, user: user} do
      by_username =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username_or_email" => user.username, "password" => "wrong"}
        })

      assert Phoenix.Flash.get(by_username.assigns.flash, :error) ==
               "Invalid username or password"

      assert Phoenix.Flash.get(by_username.assigns.flash, :username_or_email) ==
               user.username

      by_email =
        post(build_conn(), ~p"/users/log_in", %{
          "user" => %{"username_or_email" => user.email, "password" => "wrong"}
        })

      assert Phoenix.Flash.get(by_email.assigns.flash, :error) == "Invalid email or password"
    end

    test "a failed post-registration sign-in says so instead of blaming registration",
         %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "_action" => "registered",
          "post_auth_token" => post_auth_token(:registered, user),
          "user" => %{"username" => user.username, "email" => user.email, "password" => "wrong"}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log_in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "could not sign you in automatically"
    end

    test "a username/password login without a post-auth token is a normal login",
         %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log_in", %{
          "user" => %{"username" => user.username, "password" => "wrong"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid username or password"
    end

    test "a registration whose confirmation email failed still signs in, with a warning",
         %{conn: conn, user: user} do
      token =
        Phoenix.Token.sign(Website45sV3Web.Endpoint, "post-auth", {
          :registered,
          user.id,
          :confirmation_email_failed
        })

      conn =
        post(conn, ~p"/users/log_in", %{
          "_action" => "registered",
          "post_auth_token" => token,
          "user" => %{
            "username" => user.username,
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "could not send your confirmation email"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "/users/confirm"
    end
  end

  describe "DELETE /users/log_out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log_out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log_out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end

  defp post_auth_token(purpose, user) do
    Phoenix.Token.sign(Website45sV3Web.Endpoint, "post-auth", {purpose, user.id})
  end
end
