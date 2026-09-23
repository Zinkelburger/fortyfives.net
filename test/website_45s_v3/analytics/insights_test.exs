defmodule Website45sV3.Analytics.InsightsTest do
  use ExUnit.Case, async: true

  alias Website45sV3.Analytics.Insights
  alias Website45sV3.Analytics.SiteEvent
  alias Website45sV3.Game.GameLog

  @now ~N[2026-09-23 12:00:00]

  defp event(visitor, name, attrs \\ %{}) do
    struct!(
      SiteEvent,
      Map.merge(
        %{
          visitor_id: visitor,
          player_id: "seat_" <> visitor,
          name: name,
          device: "desktop",
          data: %{},
          inserted_at: ~N[2026-09-23 10:00:00]
        },
        attrs
      )
    )
  end

  # A one-human game: seat 0 is `player_id`, seats 1-3 are bots. `own` are
  # seat 0's moves as {t, type, by_bot?}.
  defp game(id, name, player_id, own, opts \\ []) do
    bot_moves = [
      %{"t" => 1_000, "e" => "bid", "p" => 1, "b" => true},
      %{"t" => 2_000, "e" => "bid", "p" => 2, "b" => true}
    ]

    mine =
      for {t, type, bot?} <- own, do: %{"t" => t, "e" => type, "p" => 0, "b" => bot?}

    events =
      [%{"t" => 0, "e" => "deal", "hand" => 1}] ++
        Enum.sort_by(bot_moves ++ mine ++ Keyword.get(opts, :extra, []), & &1["t"])

    %{
      log: %GameLog{
        id: id,
        game_name: name,
        ended: Keyword.get(opts, :ended, "finished"),
        human_count: 1,
        inserted_at: ~N[2026-09-23 10:05:00]
      },
      document: %{
        "players" => [
          %{"seat" => 0, "id" => player_id, "bot" => false},
          %{"seat" => 1, "id" => "b1", "bot" => true},
          %{"seat" => 2, "id" => "b2", "bot" => true},
          %{"seat" => 3, "id" => "b3", "bot" => true}
        ],
        "winner" => Keyword.get(opts, :winner, "team1"),
        "events" => events
      }
    }
  end

  defp build(site_events, games) do
    Insights.build(
      %{site_events: site_events, first_seen: %{}, games: games, replays: []},
      days: 14,
      now: @now
    )
  end

  test "follows each visitor down the funnel" do
    site_events = [
      event("bouncer", "page_view", %{path: "/"}),
      event("quitter", "page_view", %{path: "/"}),
      event("quitter", "page_view", %{path: "/play"}),
      event("quitter", "bot_added"),
      event("quitter", "game_view", %{game_name: "Q"}),
      event("player", "page_view", %{path: "/play"}),
      event("player", "queue_join", %{data: %{"queue" => "public", "waiting" => 0}}),
      event("player", "game_view", %{game_name: "P1"}),
      event("player", "game_view", %{game_name: "P2"})
    ]

    games = [
      # Never moves; a bot bids for them.
      game(1, "Q", "seat_quitter", [{3_000, "bid", true}]),
      game(2, "P1", "seat_player", [{3_000, "bid", false}, {9_000, "play", false}]),
      game(3, "P2", "seat_player", [{3_000, "bid", false}])
    ]

    counts = build(site_events, games).funnel |> Enum.map(&{&1.label, &1.count}) |> Map.new()

    assert counts["Opened any page"] == 3
    assert counts["Opened /play"] == 2
    assert counts["Joined the queue or added a bot"] == 2
    assert counts["Opened a game"] == 2
    assert counts["Made a move themselves"] == 1
    assert counts["Played a whole game"] == 1
    assert counts["Played 2+ games"] == 1
  end

  test "a player has left once a bot moves for them and they never move again" do
    games = [
      # Idles once (bot bids), comes back and plays on: stayed.
      game(1, "A", "p1", [{3_000, "bid", true}, {9_000, "play", false}]),
      # Moves, then a bot takes over for good during the first hand.
      game(
        2,
        "B",
        "p2",
        [{3_000, "bid", false}, {9_000, "discard", true}, {12_000, "play", true}],
        ended: "abandoned"
      )
    ]

    report = build([], games)

    assert report.exit_points.total_games == 2
    assert report.exit_points.left == 1

    assert [%{game_id: 2, moves: 1, left_before: "discard", left_at_ms: 9_000}] =
             report.early_exits
  end

  test "times a move from the moment the turn started, skipping presence events" do
    extra = [%{"t" => 2_500, "e" => "leave", "p" => 3}]
    games = [game(1, "A", "p1", [{5_000, "bid", false}], extra: extra)]

    assert [%{action: "bid", hand: "first hand", n: 1, median_ms: 3_000}] =
             build([], games).decision_times
  end

  test "bot difficulty counts only lone humans who finished" do
    games = [
      game(1, "A", "p1", [{3_000, "bid", false}], winner: "team1"),
      game(2, "B", "p2", [{3_000, "bid", false}], winner: "team2"),
      game(3, "C", "p3", [{3_000, "bid", true}], winner: "team1")
    ]

    assert %{games: 2, won: 50} = build([], games).bots
  end

  test "games get the device of the browser that opened them" do
    site_events = [event("v", "game_view", %{game_name: "A", player_id: "p1", device: "mobile"})]
    games = [game(1, "A", "p1", [{3_000, "bid", false}]), game(2, "B", "p2", [])]

    devices = build(site_events, games).devices |> Map.new(&{&1.device, &1.games})
    assert devices == %{"mobile" => 1, "unknown" => 1}
  end

  test "attributes each visitor to the referrer of their first page" do
    site_events = [
      event("a", "page_view", %{path: "/", referrer: "google.com"}),
      event("a", "game_view", %{game_name: "A"}),
      event("b", "page_view", %{path: "/"})
    ]

    assert [
             %{source: _, visitors: 1},
             %{source: _, visitors: 1}
           ] = referrers = build(site_events, []).referrers

    assert %{played: 1} = Enum.find(referrers, &(&1.source == "google.com"))
    assert %{played: 0} = Enum.find(referrers, &(&1.source == "(direct / unknown)"))
  end
end
