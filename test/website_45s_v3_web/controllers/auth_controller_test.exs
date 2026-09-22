defmodule Website45sV3Web.AuthControllerTest do
  use Website45sV3Web.ConnCase, async: false

  import Website45sV3.AccountsFixtures

  alias Website45sV3.Accounts
  alias Website45sV3Web.AuthController

  # `plug Ueberauth` runs the real Google strategy on the callback route, so
  # the interesting branches are driven by invoking the action with the
  # `ueberauth_auth` assign the plug would have produced.
  defp callback_with(conn, auth) do
    conn
    |> init_test_session(%{})
    |> fetch_flash()
    |> assign(:ueberauth_auth, auth)
    |> AuthController.callback(%{})
  end

  describe "GET /auth/google/callback" do
    test "a callback the strategy rejects is a flash and a redirect", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/callback")

      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Authentication failed"
      refute get_session(conn, :user_token)
    end
  end

  describe "callback/2 with a Google identity" do
    test "creates and signs in a new user", %{conn: conn} do
      conn = callback_with(conn, google_auth(email: "brand.new@example.com"))

      assert redirected_to(conn) == ~p"/"
      assert token = get_session(conn, :user_token)
      assert user = Accounts.get_user_by_session_token(token)
      assert user.email == "brand.new@example.com"
      assert user.confirmed_at
    end

    test "signs in an already-linked user", %{conn: conn} do
      auth = google_auth()
      {:ok, existing} = Accounts.get_or_create_google_user(auth)

      conn = callback_with(conn, auth)

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token)).id == existing.id
    end

    test "links and signs in a confirmed local account", %{conn: conn} do
      user = confirmed_user_fixture()
      conn = callback_with(conn, google_auth(email: user.email, uid: "google-linked"))

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(get_session(conn, :user_token)).id == user.id
      assert Accounts.get_user!(user.id).google_uid == "google-linked"
    end

    test "refuses an unconfirmed local account with a clear message", %{conn: conn} do
      user = user_fixture()
      conn = callback_with(conn, google_auth(email: user.email))

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log_in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "An account with this email exists but is not confirmed. " <>
                 "Confirm it or reset its password first."
    end

    test "refuses an unverified Google email", %{conn: conn} do
      conn = callback_with(conn, google_auth(email_verified: false))

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "has not verified"
    end

    test "refuses a profile without an email", %{conn: conn} do
      conn = callback_with(conn, google_auth(email: nil))

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not share an email"
    end

    test "refuses an email already linked to another Google account", %{conn: conn} do
      user = confirmed_user_fixture()
      {:ok, _} = Accounts.get_or_create_google_user(google_auth(email: user.email, uid: "g-1"))

      conn = callback_with(conn, google_auth(email: user.email, uid: "g-2"))

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "different Google account"
    end

    test "keeps the anonymous player id across sign-in", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{user_id: "seat-123"})
        |> fetch_flash()
        |> assign(:ueberauth_auth, google_auth())
        |> AuthController.callback(%{})

      assert get_session(conn, :user_token)
      assert get_session(conn, :user_id) == "seat-123"
    end
  end
end
