defmodule Website45sV3Web.AdminControllerTest do
  use Website45sV3Web.ConnCase, async: false

  alias Website45sV3.Analytics
  alias Website45sV3.Game.GameEvents
  alias Website45sV3.Game.GameLog
  alias Website45sV3.Repo

  setup :register_and_log_in_user

  defp make_admin(user) do
    Application.put_env(:website_45s_v3, :admin_usernames, [user.username])
    on_exit(fn -> Application.put_env(:website_45s_v3, :admin_usernames, []) end)
  end

  defp finished_game! do
    state =
      Map.merge(GameEvents.init(), %{
        game_name: "ADMIN1",
        player_ids: ["a", "b", "c", "d"],
        player_map: %{"a" => "Ann", "b" => "Bot1", "c" => "Bot2", "d" => "Bot3"},
        seat_bots: MapSet.new(["b", "c", "d"]),
        phase: "Final Scoring",
        team_scores: %{team1: 120, team2: 30},
        winning_team: :team1,
        team_1_history: ["x"]
      })
      |> GameEvents.log("bid", %{p: 0, v: 20, s: :hearts, b: false})

    attrs =
      state
      |> GameEvents.finalize(:normal)
      |> Map.put(:player_usernames, ["Ann", "Bot1", "Bot2", "Bot3"])

    {:ok, log} = %GameLog{} |> GameLog.changeset(attrs) |> Repo.insert()
    log
  end

  test "non-admins are sent home", %{conn: conn} do
    conn = get(conn, ~p"/admin")
    assert redirected_to(conn) == ~p"/"
  end

  test "anonymous visitors are sent to log in" do
    conn = get(build_conn(), ~p"/admin")
    assert redirected_to(conn) == ~p"/users/log_in"
  end

  test "admins see games, timelines, replays and raw logs", %{conn: conn, user: user} do
    make_admin(user)
    log = finished_game!()

    {:ok, replay} =
      Analytics.start_replay(%{
        game_name: "ADMIN1",
        player_id: "a",
        display_name: "Ann",
        device: "mobile",
        viewport_w: 390,
        viewport_h: 800
      })

    # A click 8s into the game, reported by a browser whose clock is an
    # hour slow; it is stored on the server's clock so the timeline still
    # places it after the bid.
    {:ok, started_at, _} =
      DateTime.from_iso8601(Jason.decode!(:zlib.gunzip(log.events))["started_at"])

    start_ms = DateTime.to_unix(started_at, :millisecond)
    skew = 3_600_000

    clicks =
      Analytics.clicks_from_client(
        [%{"ts" => start_ms + 8_000 - skew, "el" => "button.blue-button", "dead" => true}],
        start_ms + 9_000 - skew,
        start_ms + 9_000
      )

    {:ok, _} = Analytics.append_chunk(replay, 0, ~s([{"type":4,"timestamp":1}]), clicks)

    html = conn |> get(~p"/admin") |> html_response(200)
    assert html =~ "Ann, Bot1, Bot2, Bot3"
    assert html =~ "finished"
    assert html =~ ~p"/admin/replays/#{replay.id}"
    assert html =~ "/assets/admin.js"

    html = conn |> get(~p"/admin/games/#{log.id}") |> html_response(200)
    assert html =~ "Ann bids 20 hearts"
    assert html =~ "winner: team1"
    assert html =~ "00:08.0  [+8.0s] Ann clicked button.blue-button DEAD CLICK"

    json = conn |> get(~p"/admin/games/#{log.id}/events.json") |> json_response(200)
    assert json["game"] == "ADMIN1"

    html = conn |> get(~p"/admin/replays/#{replay.id}") |> html_response(200)
    assert html =~ ~s(id="replay-player")

    assert [%{"type" => 4}] =
             conn |> get(~p"/admin/replays/#{replay.id}/events.json") |> json_response(200)
  end
end
