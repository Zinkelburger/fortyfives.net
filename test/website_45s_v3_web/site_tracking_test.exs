defmodule Website45sV3Web.SiteTrackingTest do
  use Website45sV3Web.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Website45sV3.Analytics.SiteEvent
  alias Website45sV3.Repo

  defp events, do: Repo.all(from(e in SiteEvent, order_by: e.id))

  test "a browser gets a long-lived visitor cookie that is kept across requests", %{conn: conn} do
    conn = get(conn, ~p"/")
    %{value: visitor_id, max_age: max_age} = conn.resp_cookies["ff_vid"]
    assert {:ok, _} = Ecto.UUID.cast(visitor_id)
    assert max_age >= 60 * 60 * 24 * 300

    again = conn |> recycle() |> get(~p"/learn")
    assert again.resp_cookies["ff_vid"].value == visitor_id
  end

  test "a garbled visitor cookie is replaced", %{conn: conn} do
    conn = conn |> put_req_cookie("ff_vid", "not-a-uuid") |> get(~p"/")
    assert {:ok, _} = Ecto.UUID.cast(conn.resp_cookies["ff_vid"].value)
  end

  test "a connected page view is recorded with its route, device and referrer", %{conn: conn} do
    conn =
      conn
      |> put_req_header("user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Mobile/15E148")
      |> put_connect_params(%{
        "_vw" => 390,
        "_vh" => 844,
        "_ref" => "https://www.Google.com/search?q=45s"
      })

    {:ok, _view, _html} = live(conn, ~p"/learn")

    assert [
             %SiteEvent{
               name: "page_view",
               path: "/learn",
               device: "mobile",
               viewport_w: 390,
               viewport_h: 844,
               referrer: "google.com",
               visitor_id: visitor_id
             }
           ] = events()

    assert is_binary(visitor_id)
  end

  test "crawlers are not recorded", %{conn: conn} do
    conn = put_req_header(conn, "user-agent", "Mozilla/5.0 (compatible; Googlebot/2.1)")
    {:ok, _view, _html} = live(conn, ~p"/learn")

    assert events() == []
  end

  test "paths are stored as route patterns, without ids or tokens", %{conn: conn} do
    {:ok, _view, _html} = live(conn, ~p"/users/confirm/secret-token")

    assert [%SiteEvent{path: "/users/confirm/:token"}] = events()
  end

  test "joining the queue and adding a bot are recorded", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/play")
    render_click(view, "join")
    render_click(view, "leave")

    assert [
             %SiteEvent{name: "page_view", path: "/play"},
             %SiteEvent{name: "queue_join", data: %{"queue" => "public"}},
             %SiteEvent{name: "queue_leave", data: %{"waited_ms" => waited}}
           ] = events()

    assert is_integer(waited)
  end
end
