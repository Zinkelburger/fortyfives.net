defmodule Website45sV3Web.UserForgotPasswordLiveTest do
  use Website45sV3Web.ConnCase

  import Phoenix.LiveViewTest
  import Website45sV3.AccountsFixtures

  alias Website45sV3.Accounts
  alias Website45sV3.Repo

  describe "Forgot password page" do
    test "renders email page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/reset_password")

      assert html =~ "Forgot your password?"
      assert has_element?(lv, ~s|a[href="#{~p"/users/register"}"]|, "Register")
      assert has_element?(lv, ~s|a[href="#{~p"/users/log_in"}"]|, "Log in")
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/reset_password")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end
  end

  describe "Reset link" do
    setup do
      %{user: user_fixture()}
    end

    test "sends a new reset password token", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{"email" => user.email})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"

      assert Repo.get_by!(Accounts.UserToken, user_id: user.id).context ==
               "reset_password"
    end

    test "does not send reset password token if email is invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{"email" => "unknown@example.com"})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      assert Repo.all(Accounts.UserToken) == []
    end

    test "refuses to send when the Turnstile challenge fails", %{conn: conn, user: user} do
      Website45sV3.TurnstileStub.force_failure()
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      result =
        lv
        |> form("#reset_password_form", user: %{"email" => user.email})
        |> render_submit()

      assert result =~ "Please complete the verification challenge"
      assert Repo.all(Accounts.UserToken) == []
    end

    test "refuses to send once the address has had its allowance", %{conn: conn, user: user} do
      alias Website45sV3.Security.RateLimiter

      previous = Application.get_env(:website_45s_v3, :security_rate_limits)
      Application.put_env(:website_45s_v3, :security_rate_limits, email: [max_address: 1])

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous)
        RateLimiter.reset()
      end)

      RateLimiter.reset()
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      {:ok, _conn} =
        lv
        |> form("#reset_password_form", user: %{"email" => user.email})
        |> render_submit()
        |> follow_redirect(conn, "/")

      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      result =
        lv
        |> form("#reset_password_form", user: %{"email" => user.email})
        |> render_submit()

      assert result =~ "Too many requests"
      assert length(Repo.all(Accounts.UserToken)) == 1
    end

    test "does not reveal a delivery failure", %{conn: conn, user: user} do
      Website45sV3.FailingMailAdapter.enable()
      {:ok, lv, _html} = live(conn, ~p"/users/reset_password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", user: %{"email" => user.email})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
    end
  end
end
