defmodule Website45sV3Web.UserRegistrationLiveTest do
  use Website45sV3Web.ConnCase

  import Phoenix.LiveViewTest
  import Website45sV3.AccountsFixtures

  alias Website45sV3.Security.RateLimiter

  # Every submit that reaches the database is charged to loopback's budget.
  setup do
    RateLimiter.reset()
    :ok
  end

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, "/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(
          user: %{
            "username" => "validuser",
            "email" => "with spaces",
            "password" => "short"
          }
        )

      assert result =~ "Register"
      assert result =~ "Must have the @ sign and no spaces"
      assert result =~ "should be at least 8 character"
    end
  end

  describe "register user" do
    test "creates account and logs the user in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, "/")
      response = html_response(conn, 200)
      assert response =~ "Settings"
      assert response =~ "Log out"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{
            "username" => unique_username(),
            "email" => user.email,
            "password" => "valid_password"
          }
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "probing for taken emails spends the network budget; local typos do not",
         %{conn: conn} do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)
      Application.put_env(:website_45s_v3, :security_rate_limits, registration: [max_ip: 1])
      on_exit(fn -> Application.put_env(:website_45s_v3, :security_rate_limits, previous) end)

      {:ok, lv, _html} = live(conn, ~p"/users/register")
      user = user_fixture()

      submit = fn attrs ->
        lv |> form("#registration_form", user: attrs) |> render_submit()
      end

      # Too short a password never reaches the database, so it is free.
      assert submit.(%{
               "username" => unique_username(),
               "email" => unique_user_email(),
               "password" => "short"
             }) =~
               "should be at least 8"

      assert submit.(%{
               "username" => unique_username(),
               "email" => user.email,
               "password" => "valid_password"
             }) =~
               "has already been taken"

      assert submit.(%{
               "username" => unique_username(),
               "email" => unique_user_email(),
               "password" => "valid_password"
             }) =~
               "Too many accounts created from your network"
    end

    test "renders errors for a duplicated username on submit", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      user = user_fixture()

      result =
        lv
        |> form("#registration_form",
          user: %{
            "username" => user.username,
            "email" => unique_user_email(),
            "password" => "valid_password"
          }
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "live validation does not reveal whether an email or username is taken",
         %{conn: conn} do
      # The validate event is unthrottled; reporting uniqueness there would be
      # an account-enumeration oracle. Format checks still run live.
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(
          user: %{"username" => user.username, "email" => user.email, "password" => "short"}
        )

      refute result =~ "has already been taken"
      assert result =~ "should be at least 8 character"
    end

    test "still signs the user in when the confirmation email cannot be sent",
         %{conn: conn} do
      Website45sV3.FailingMailAdapter.enable()
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Website45sV3.Accounts.get_user_by_email(email)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "could not send your confirmation email"
    end

    test "refuses to register when the Turnstile challenge fails", %{conn: conn} do
      Website45sV3.TurnstileStub.force_failure()
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      result =
        lv
        |> form("#registration_form", user: valid_user_attributes(email: email))
        |> render_submit()

      assert result =~ "Please complete the verification challenge"
      refute Website45sV3.Accounts.get_user_by_email(email)
    end

    test "refuses to register once the network has created its allowance", %{conn: conn} do
      previous = Application.get_env(:website_45s_v3, :security_rate_limits)
      Application.put_env(:website_45s_v3, :security_rate_limits, registration: [max_ip: 1])

      on_exit(fn ->
        Application.put_env(:website_45s_v3, :security_rate_limits, previous)
        RateLimiter.reset()
      end)

      RateLimiter.reset()
      # The test client connects from loopback.
      RateLimiter.check_registration("127.0.0.1")

      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      result =
        lv
        |> form("#registration_form", user: valid_user_attributes(email: email))
        |> render_submit()

      assert result =~ "Too many accounts created from your network"
      refute Website45sV3.Accounts.get_user_by_email(email)
    end

    test "the password field is never echoed back after validation", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(
          user: %{
            "username" => "validuser",
            "email" => "valid@example.com",
            "password" => "hunter2hunter2"
          }
        )

      refute result =~ "hunter2hunter2"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element(~s|header a[href="/users/log_in"]|)
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log_in")

      assert login_html =~ "Log in"
    end
  end
end
