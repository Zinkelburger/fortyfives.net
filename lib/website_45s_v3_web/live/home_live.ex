defmodule Website45sV3Web.HomeLive do
  use Website45sV3Web, :live_view

  alias Website45sV3Web.PageHTML

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Forty Fives | Play the 45s Card Game Online Free",
       meta_description:
         "Play the 45s card game online for free. Forty Fives (45s) is a classic trick-taking card game. Create a table, invite friends, and play in your browser. No download needed."
     )}
  end

  def render(assigns), do: PageHTML.home(assigns)
end
