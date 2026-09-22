defmodule Website45sV3Web.HomeLiveTest do
  use Website45sV3Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "GET / renders the home page with a strict CSP", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Forty Fives | Play the 45s Card Game Online Free"
    assert response =~ "Play Online"
    assert response =~ ~s(<nav aria-label="Main")
    assert response =~ ~s(<link rel="canonical" href="https://fortyfives.net/")
    refute response =~ ~s(<meta name="robots" content="noindex")

    assert get_resp_header(conn, "content-security-policy") |> List.first() =~
             "object-src 'none'"
  end

  test "the page description feeds the social previews", %{conn: conn} do
    response = conn |> get(~p"/learn") |> html_response(200)

    assert response =~
             ~s(<meta property="og:description" content="Learn how to play the 45s card game)

    assert response =~
             ~s(<meta name="twitter:description" content="Learn how to play the 45s card game)
  end

  test "the home page links to the private lobby tab", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/play?tab=private")
  end
end
