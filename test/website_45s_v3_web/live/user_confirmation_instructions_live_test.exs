defmodule Website45sV3Web.UserConfirmationInstructionsLiveTest do
  use Website45sV3Web.ConnCase

  import Phoenix.LiveViewTest
  import Website45sV3.AccountsFixtures

  alias Website45sV3.Accounts
  alias Website45sV3.Repo

  setup do
    %{user: user_fixture()}
  end

  describe "Resend confirmation" do
    test "renders the resend confirmation page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/confirm")
      assert html =~ "Resend confirmation instructions"
    end

    test "sends a new confirmation token", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/confirm")

      {:ok, conn} =
        lv
        |> form("#resend_confirmation_form", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "If your email is in our system"

      assert Repo.get_by!(Accounts.UserToken, user_id: user.id).context == "confirm"
    end

    test "does not send confirmation token if user is confirmed", %{conn: conn, user: user} do
      Repo.update!(Accounts.User.confirm_changeset(user))

      {:ok, lv, _html} = live(conn, ~p"/users/confirm")

      {:ok, conn} =
        lv
        |> form("#resend_confirmation_form", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "If your email is in our system"

      refute Repo.get_by(Accounts.UserToken, user_id: user.id)
    end

    test "does not send confirmation token if email is invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/confirm")

      {:ok, conn} =
        lv
        |> form("#resend_confirmation_form", user: %{email: "unknown@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "If your email is in our system"

      assert Repo.all(Accounts.UserToken) == []
    end

    test "refuses to send when the Turnstile challenge fails", %{conn: conn, user: user} do
      Website45sV3.TurnstileStub.force_failure()
      {:ok, lv, _html} = live(conn, ~p"/users/confirm")

      result =
        lv
        |> form("#resend_confirmation_form", user: %{email: user.email})
        |> render_submit()

      assert result =~ "Please complete the verification challenge"
      assert Repo.all(Accounts.UserToken) == []
    end

    test "refuses to send once the network has had its allowance", %{conn: conn, user: user} do
      alias Website45sV3.Security.RateLimiter

      previous = Application.get_env(:website_45s_v3, :security_rate_limits)
      Application.put_env(:website_45s_v3, :security_rate_limits, email: [max_ip: 1])

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous)
        RateLimiter.reset()
      end)

      RateLimiter.reset()
      # The test client connects from loopback; any address spends its budget.
      :ok = RateLimiter.check_email_send("127.0.0.1", "someone-else@example.com")

      {:ok, lv, _html} = live(conn, ~p"/users/confirm")

      result =
        lv
        |> form("#resend_confirmation_form", user: %{email: user.email})
        |> render_submit()

      assert result =~ "Too many requests"
      assert Repo.all(Accounts.UserToken) == []
    end

    test "does not reveal a delivery failure", %{conn: conn, user: user} do
      Website45sV3.FailingMailAdapter.enable()
      {:ok, lv, _html} = live(conn, ~p"/users/confirm")

      {:ok, conn} =
        lv
        |> form("#resend_confirmation_form", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
    end
  end
end
