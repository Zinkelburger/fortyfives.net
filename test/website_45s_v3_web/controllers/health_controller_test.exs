defmodule Website45sV3Web.HealthControllerTest do
  use Website45sV3Web.ConnCase, async: true

  test "GET /healthz answers ok in plain text when the database responds", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert text_response(conn, 200) == "ok"
  end

  test "GET /healthz sets no session cookie and no CSP", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert conn.resp_cookies == %{}
    assert get_resp_header(conn, "content-security-policy") == []
  end
end
