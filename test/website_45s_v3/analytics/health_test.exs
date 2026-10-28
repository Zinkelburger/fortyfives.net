defmodule Website45sV3.Analytics.HealthTest do
  use Website45sV3.DataCase, async: false

  alias Website45sV3.Analytics.Health
  alias Website45sV3.Analytics.SiteEvent
  alias Website45sV3.Game.GameLog

  # A game log with `humans` at seats 0.., bots in the rest, and a join event
  # for each seat in `joined`.
  defp game_log(game_name, ended, humans, joined) do
    players =
      for seat <- 0..3,
          do: %{"seat" => seat, "id" => "p#{seat}", "bot" => seat >= humans}

    events = [
      %{"e" => "deal", "t" => 0} | Enum.map(joined, &%{"e" => "join", "p" => &1, "t" => 5})
    ]

    document = %{"v" => 1, "players" => players, "events" => events}

    %GameLog{}
    |> GameLog.changeset(%{
      player_usernames: ["a", "b", "c", "d"],
      game_name: game_name,
      ended: ended,
      human_count: humans,
      events: :zlib.gzip(Jason.encode!(document))
    })
    |> Repo.insert!()
  end

  defp site_event(name, data \\ %{}) do
    %SiteEvent{}
    |> SiteEvent.changeset(%{visitor_id: "v-#{name}", name: name, data: data})
    |> Repo.insert!()
  end

  test "counts how games ended and the human seats that never connected" do
    game_log("ALLHERE", "finished", 2, [0, 1, 2, 3])
    game_log("GHOST", "abandoned", 2, [0, 2, 3])
    game_log("CRASHED", "crash", 1, [0])

    report = Health.report(days: 1)

    assert %{total: 3, finished: 1, abandoned: 1, crash: 1} = report.games
    assert report.games.human_seats == 5
    assert report.games.no_show_seats == 1
    assert report.games.no_show_games == ["GHOST"]
  end

  test "counts queue departures by reason" do
    site_event("queue_join")
    site_event("queue_join")
    site_event("queue_leave", %{"reason" => "disconnect"})
    site_event("queue_leave", %{"reason" => "explicit"})

    assert %{joins: 2, departures: %{"disconnect" => 1, "explicit" => 1}} =
             Health.report(days: 1).queue
  end

  test "renders as text" do
    game_log("GHOST", "abandoned", 2, [0])
    text = Health.text(days: 1)

    assert text =~ "no-show seats: 1 of 2 human seats (GHOST)"
    assert text =~ "crashed 0"
    assert text =~ "departures: none"
  end

  test "leaves out anything older than the window" do
    log = game_log("OLD", "finished", 1, [0])
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -3, :day)
    Repo.update_all(from(g in GameLog, where: g.id == ^log.id), set: [inserted_at: old])

    assert Health.report(days: 1).games.total == 0
    assert Health.report(days: 7).games.total == 1
  end
end
