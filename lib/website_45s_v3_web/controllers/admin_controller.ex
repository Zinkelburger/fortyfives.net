defmodule Website45sV3Web.AdminController do
  @moduledoc """
  Read-only analytics pages for admins (see `UserAuth.require_admin/2`):
  recent games with their event logs, the browser session replays recorded
  at each table, and the insights report built from both plus site events.
  """
  use Website45sV3Web, :controller

  alias Website45sV3.Analytics
  alias Website45sV3.Analytics.Insights
  alias Website45sV3.Analytics.Timeline
  alias Website45sV3.Game.GameEvents

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Games | Admin",
      games: Analytics.list_game_logs(limit: 200),
      replays: Analytics.list_replays(limit: 50),
      replay_bytes: Analytics.replay_bytes()
    )
  end

  def insights(conn, params) do
    days = params |> Map.get("days", "14") |> Integer.parse() |> days_or_default()

    render(conn, :insights,
      page_title: "Insights | Admin",
      report: Insights.report(days: days)
    )
  end

  defp days_or_default({days, ""}) when days in 1..365, do: days
  defp days_or_default(_), do: 14

  def game(conn, %{"id" => id}) do
    log = Analytics.get_game_log!(id)
    replays = Analytics.list_replays(game_name: log.game_name)

    {document, timeline} =
      case GameEvents.decode(log.events) do
        {:ok, document} ->
          clicks =
            log.game_name
            |> Analytics.list_clicks()
            |> Timeline.on_game_clock(parse_started_at(document))

          {document, Timeline.text(document, clicks)}

        {:error, _} ->
          {nil, nil}
      end

    render(conn, :game,
      page_title: "Game #{log.id} | Admin",
      log: log,
      document: document,
      timeline: timeline,
      replays: replays
    )
  end

  def game_events(conn, %{"id" => id}) do
    log = Analytics.get_game_log!(id)

    case log.events do
      nil ->
        send_resp(conn, 404, "no event log for this game")

      gz ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, :zlib.gunzip(gz))
    end
  end

  def replay(conn, %{"id" => id}) do
    replay = Analytics.get_replay!(id)

    render(conn, :replay,
      page_title: "Replay #{replay.id} | Admin",
      replay: replay,
      game_log: Analytics.get_game_log_by_name(replay.game_name)
    )
  end

  def replay_events(conn, %{"id" => id}) do
    replay = Analytics.get_replay!(id)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Analytics.replay_events_json(replay))
  end

  defp parse_started_at(%{"started_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_started_at(_document), do: nil
end
