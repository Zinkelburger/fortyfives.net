defmodule Website45sV3Web.PageControllerTest do
  use Website45sV3Web.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Forty Fives | Play the 45s Card Game Online Free"
    assert response =~ "Play"
  end
end
