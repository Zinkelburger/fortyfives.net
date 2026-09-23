defmodule Website45sV3Web.VisitorId do
  @moduledoc """
  Gives every browser a long-lived anonymous visitor id, so analytics can
  tell a returning visitor from a new one. The seat id in the session
  (`:user_id`) lasts only as long as the browser session; this cookie lasts
  a year.

  The id is copied into the session so LiveViews, which only see the
  session, can read it. It identifies nothing but the browser and carries
  no authority: a forged value only skews the stats.
  """
  import Plug.Conn

  @cookie "ff_vid"
  @max_age 60 * 60 * 24 * 365
  @cookie_options [
    max_age: @max_age,
    http_only: true,
    same_site: "Lax",
    secure: Application.compile_env(:website_45s_v3, :secure_cookies, false)
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    visitor_id = valid_or_new(conn.cookies[@cookie])

    conn = put_resp_cookie(conn, @cookie, visitor_id, @cookie_options)

    if get_session(conn, :visitor_id) == visitor_id,
      do: conn,
      else: put_session(conn, :visitor_id, visitor_id)
  end

  defp valid_or_new(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      :error -> Ecto.UUID.generate()
    end
  end

  defp valid_or_new(_id), do: Ecto.UUID.generate()
end
