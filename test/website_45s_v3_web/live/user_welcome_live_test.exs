defmodule Website45sV3Web.UserWelcomeLiveTest do
  use Website45sV3Web.ConnCase

  alias Website45sV3.Accounts
  alias Website45sV3.Security.RateLimiter
  import Phoenix.LiveViewTest
  import Website45sV3.AccountsFixtures

  setup %{conn: conn} do
    RateLimiter.reset()
    {:ok, user} = Accounts.get_or_create_google_user(google_auth())
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "lobby pages" do
    test "send a Google sign-up on a generated name to pick one", %{conn: conn, user: user} do
      assert user.username_pending
      assert "player_" <> _ = user.username

      for path <- [~p"/", ~p"/learn"] do
        assert {:error, {:redirect, %{to: to}}} = live(conn, path)
        assert to == ~p"/users/welcome?#{[return_to: path]}"
      end
    end

    test "leave everyone else alone", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert {:ok, _lv, _html} = live(conn, ~p"/learn")
    end

    test "stop sending them once they keep the generated name", %{conn: conn, user: user} do
      {:ok, _user} = Accounts.keep_username(user)
      assert {:ok, _lv, _html} = live(conn, ~p"/learn")
    end
  end

  describe "welcome page" do
    test "starts empty and offers to keep the generated name", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/users/welcome?return_to=/play")

      assert html =~ "Pick the name other players see at the table."
      assert html =~ "Save and play"
      assert html =~ "Keep #{user.username}"
      assert lv |> element("#user_username") |> render() =~ ~s(value="")
    end

    test "saves a chosen name and returns to the lobby page", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/welcome?return_to=/learn")
      name = "Chosen_#{System.unique_integer([:positive])}"

      assert {:ok, conn} =
               lv
               |> form("#welcome_form", %{"user" => %{"username" => name}})
               |> render_submit()
               |> follow_redirect(conn, "/learn")

      assert html_response(conn, 200) =~ "You&#39;re playing as #{name}."
      user = Accounts.get_user!(user.id)
      assert user.username == name
      refute user.username_pending
    end

    test "keeps the generated name", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/welcome?return_to=/learn")

      assert {:error, {:redirect, %{to: "/learn"}}} =
               lv |> element("#keep_username") |> render_click()

      kept = Accounts.get_user!(user.id)
      assert kept.username == user.username
      refute kept.username_pending
    end

    test "treats submitting the generated name as keeping it", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/welcome")

      assert {:error, {:redirect, %{to: "/"}}} =
               lv
               |> form("#welcome_form", %{"user" => %{"username" => user.username}})
               |> render_submit()

      refute Accounts.get_user!(user.id).username_pending
    end

    test "refuses a name that is taken or banned", %{conn: conn, user: user} do
      other = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/welcome")

      for {name, error} <- [
            {other.username, "has already been taken"},
            {"admin", "Contains a banned word"}
          ] do
        result =
          lv
          |> form("#welcome_form", %{"user" => %{"username" => name}})
          |> render_submit()

        assert result =~ error
      end

      assert Accounts.get_user!(user.id).username_pending
    end

    test "only returns to lobby pages", %{conn: conn} do
      private = "/play/private/#{Ecto.UUID.generate()}"
      {:ok, _lv, html} = live(conn, ~p"/users/welcome?#{[return_to: private]}")
      assert html =~ "Save and play"

      for unsafe <- ["//evil.example", "https://evil.example/", "/admin", "/play/private/../x"] do
        # Keeping the name ends the offer, so each case needs a fresh sign-up.
        {:ok, user} = Accounts.get_or_create_google_user(google_auth())
        conn = log_in_user(build_conn(), user)
        {:ok, lv, _html} = live(conn, ~p"/users/welcome?#{[return_to: unsafe]}")

        assert {:error, {:redirect, %{to: "/"}}} =
                 lv |> element("#keep_username") |> render_click()
      end
    end

    test "sends anyone not being offered a name straight on", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:error, {:redirect, %{to: "/play"}}} =
               live(conn, ~p"/users/welcome?return_to=/play")
    end

    test "requires signing in", %{conn: _conn} do
      assert {:error, {:redirect, %{to: "/users/log_in"}}} =
               live(build_conn(), ~p"/users/welcome")
    end
  end

  describe "settings" do
    test "changing the username there also stops the offer", %{user: user} do
      {:ok, renamed} = Accounts.update_user_username(user, %{"username" => "Renamed_#{user.id}"})
      refute renamed.username_pending
    end
  end
end
