defmodule Website45sV3Web.LearnLive do
  use Website45sV3Web, :live_view

  alias Website45sV3Web.PageHTML

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "How to Play 45s | Forty Fives Card Game Rules",
       meta_description:
         "Learn how to play the 45s card game online for free. Complete Forty Fives rules — card rankings, bidding, tricks, scoring, and reneging. Play 45s at fortyfives.net."
     )}
  end

  def render(assigns), do: PageHTML.learn(assigns)
end
