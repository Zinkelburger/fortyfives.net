defmodule Website45sV3Web.HealthController do
  @moduledoc """
  `GET /healthz` for container healthchecks and uptime monitors.

  Answers `200 ok` when the application is up and the database answers a
  trivial query, `503 unavailable` otherwise. Plain text, no session, no
  layout.
  """

  use Website45sV3Web, :controller

  alias Ecto.Adapters.SQL
  alias Website45sV3.Repo

  def index(conn, _params) do
    conn = put_resp_content_type(conn, "text/plain")

    case database_status() do
      :ok -> send_resp(conn, 200, "ok")
      :error -> send_resp(conn, 503, "unavailable")
    end
  end

  # A pool with no free connection raises rather than returning an error
  # tuple; that is a 503 too.
  defp database_status do
    case SQL.query(Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    DBConnection.ConnectionError -> :error
  end
end
