defmodule Website45sV3Web.HealthControllerTest do
  use Website45sV3Web.ConnCase, async: false

  test "GET /healthz answers ok in plain text when the database responds", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert text_response(conn, 200) == "ok"
  end

  test "GET /healthz sets no session cookie and no CSP", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert conn.resp_cookies == %{}
    assert get_resp_header(conn, "content-security-policy") == []
  end

  describe "GET /healthz/auth" do
    setup do
      Website45sV3.Turnstile.reset_last_outcome()
      Website45sV3.AuthHealth.clear_cache()

      Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
        client_id: "",
        client_secret: ""
      )

      on_exit(fn ->
        Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
        Website45sV3.AuthHealth.clear_cache()
      end)
    end

    test "answers 503 with every check when one fails", %{conn: conn} do
      conn = get(conn, ~p"/healthz/auth")

      assert json_response(conn, 503) == %{
               "status" => "fail",
               "checks" => %{
                 "turnstile_secret" => "disabled",
                 "turnstile_verifications" => "ok",
                 "google_oauth" => "fail: client id or secret not set"
               }
             }

      assert conn.resp_cookies == %{}
    end
  end
end
