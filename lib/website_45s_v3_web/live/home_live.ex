defmodule Website45sV3Web.HomeLive do
  use Website45sV3Web, :live_view

  alias Website45sV3Web.PageHTML

  def render(assigns), do: PageHTML.home(assigns)
end
