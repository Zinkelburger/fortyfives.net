defmodule Website45sV3Web.PageControllerTest do
  use Website45sV3Web.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Welcome to fortyfives.net"
    assert response =~ "Play Online"
  end
end
