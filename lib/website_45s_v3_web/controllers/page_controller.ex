defmodule Website45sV3Web.PageController do
  use Website45sV3Web, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def learn(conn, _params) do
    render(conn, :learn)
  end
end
