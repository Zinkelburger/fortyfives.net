defmodule Website45sV3Web.LearnLive do
  use Website45sV3Web, :live_view

  alias Website45sV3Web.PageHTML

  def render(assigns), do: PageHTML.learn(assigns)
end
