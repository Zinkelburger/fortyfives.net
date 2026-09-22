defmodule Website45sV3Web.ErrorHTMLTest do
  use Website45sV3Web.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template

  alias Website45sV3Web.ErrorHTML

  test "renders a styled 404 page" do
    html = render_to_string(ErrorHTML, "404", "html", [])

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "<title>Page not found | Forty Fives</title>"
    assert html =~ "background: #041624"
    assert html =~ "/images/noBlue.png"
    assert html =~ ~s(<a href="/">Home</a>)
    assert html =~ ~s(href="/play")
    assert html =~ ~s(<meta name="robots" content="noindex")
  end

  test "renders a styled 500 page" do
    html = render_to_string(ErrorHTML, "500", "html", [])

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "<title>Something went wrong | Forty Fives</title>"
    assert html =~ ~s(<a href="/">Home</a>)
    assert html =~ ~s(href="/play")
  end

  test "other statuses fall back to the plain status message" do
    assert render_to_string(ErrorHTML, "403", "html", []) == "Forbidden"
  end

  test "an unknown path is served the 404 page", %{conn: conn} do
    body = conn |> get("/no-such-page") |> html_response(404)

    assert body =~ "Page not found"
    assert body =~ ~s(href="/play")
  end
end
