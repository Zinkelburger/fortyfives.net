defmodule Website45sV3.Analytics.Insights do
  @moduledoc """
  The numbers behind /admin/insights: where visitors drop off, when players
  give up on a game, how long decisions take, how the bots fare, and how all
  of that differs on phones.

  `report/1` loads a window of site events, game logs and replays; `build/2`
  is the pure part that turns them into the report, so it can be tested
  with hand-made data.

  A player's seat is followed through a game's event log: every bid, discard
  and card is marked as played by the human or by a bot standing in. A
  player has *left* once they abandon, disconnect without returning, or a
  bot plays for them and they never act again. Transient disconnects and
  temporary bot control do not count as departures.
  """

  import Ecto.Query

  alias Website45sV3.Analytics.Replay
  alias Website45sV3.Analytics.SiteEvent
  alias Website45sV3.Game.GameEvents
  alias Website45sV3.Game.GameLog
  alias Website45sV3.Repo

  @actions ~w(bid discard play)
  # Delay between a trick's last card and the next lead (GameController's
  # :trick_transition), taken off think times that start at a trick.
  @trick_pause_ms 2_000
  @presence_events ~w(join leave idle resume abandon)

  @doc """
  The report for the last `days` days (default 14).
  """
  def report(opts \\ []) do
    days = Keyword.get(opts, :days, 14)
    now = Keyword.get(opts, :now, NaiveDateTime.utc_now())
    since = NaiveDateTime.add(now, -days, :day)

    site_events =
      from(e in SiteEvent, where: e.inserted_at >= ^since, order_by: [asc: e.inserted_at])
      |> Repo.all()

    visitor_ids = site_events |> Enum.map(& &1.visitor_id) |> Enum.uniq()

    first_seen =
      from(e in SiteEvent,
        where: e.visitor_id in ^visitor_ids,
        group_by: e.visitor_id,
        select: {e.visitor_id, min(e.inserted_at)}
      )
      |> Repo.all()
      |> Map.new()

    games =
      from(g in GameLog, where: g.inserted_at >= ^since, order_by: [asc: g.inserted_at])
      |> Repo.all()
      |> Enum.flat_map(fn log ->
        case GameEvents.decode(log.events) do
          {:ok, document} -> [%{log: %{log | events: nil}, document: document}]
          _ -> []
        end
      end)

    replays =
      from(r in Replay,
        where: r.inserted_at >= ^since,
        select: map(r, [:id, :game_name, :player_id, :device, :inserted_at])
      )
      |> Repo.all()

    build(
      %{site_events: site_events, first_seen: first_seen, games: games, replays: replays},
      days: days,
      now: now
    )
  end

  @doc """
  Builds the report from loaded data. See `report/1`.
  """
  def build(data, opts) do
    seats = Enum.flat_map(data.games, &human_seats(&1, data))

    %{
      days: Keyword.fetch!(opts, :days),
      tracking_since: tracking_since(data.site_events),
      funnel: funnel(data.site_events, seats),
      visitors_by_day: visitors_by_day(data.site_events, data.first_seen),
      referrers: referrers(data.site_events),
      devices: devices(seats),
      viewports: viewports(data.site_events),
      early_exits: early_exits(seats),
      exit_points: exit_points(seats),
      decision_times: decision_times(seats),
      bots: bots(seats),
      learn: learn(data.site_events, seats),
      queue: queue(data.site_events, data.games)
    }
  end

  ## Seats

  # One entry per human seat per game, with how that player's game went.
  defp human_seats(%{log: log, document: doc}, data) do
    # Closing the results page is not dropping out of the game. Ignore
    # presence and abandon events after the winning score, in event order.
    events =
      (doc["events"] || [])
      |> Enum.take_while(&(not (&1["e"] == "score" and &1["win"] in ["team1", "team2"])))

    players = doc["players"] || []
    humans = Enum.reject(players, & &1["bot"])

    for player <- humans do
      seat = player["seat"]
      player_id = seat_player_id(player, humans)
      own = Enum.filter(events, &(&1["p"] == seat and &1["e"] in @actions))
      {mine, bots} = Enum.split_with(own, &(&1["b"] != true))
      left = departure(events, seat, mine, bots)

      %{
        game_id: log.id,
        game_name: log.game_name,
        at: log.inserted_at,
        ended: log.ended,
        human_count: length(humans),
        seat: seat,
        player_id: player_id,
        device: device_for(log.game_name, player_id, data),
        visitor_id: visitor_for(log.game_name, player_id, data.site_events),
        moves: length(mine),
        left_at_ms: left && left["t"],
        left_hand: left && hand_at(events, left["t"]),
        left_before: left && left["e"],
        stayed: is_nil(left),
        won: winner_team(doc["winner"]) == team(seat),
        think_times: think_times(events, seat)
      }
    end
  end

  # Logs written before seat ids were recorded: a lone human is still
  # unambiguous.
  defp seat_player_id(%{"id" => id}, _humans) when is_binary(id), do: id
  defp seat_player_id(_player, [_only]), do: :only_human
  defp seat_player_id(_player, _humans), do: nil

  defp departure(events, seat, own_moves, bot_moves) do
    seat_events = Enum.filter(events, &(&1["p"] == seat))
    abandon = Enum.find(seat_events, &(&1["e"] == "abandon"))

    # A join or a human move proves the player returned after a leave.
    disconnect =
      Enum.reduce(seat_events, nil, fn event, last_leave ->
        cond do
          event["e"] == "leave" -> event
          event["e"] == "join" -> nil
          event["e"] in @actions and event["b"] != true -> nil
          true -> last_leave
        end
      end)

    [abandon, disconnect, takeover(own_moves, bot_moves)]
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(& &1["t"], fn -> nil end)
  end

  # The first move a bot made for the seat after the human's last own move:
  # the moment they left for good. nil if they played to the end.
  defp takeover([], bot_moves), do: List.first(bot_moves)

  defp takeover(own_moves, bot_moves) do
    %{"t" => last} = List.last(own_moves)
    Enum.find(bot_moves, &(&1["t"] > last))
  end

  defp team(seat) when rem(seat, 2) == 0, do: :team1
  defp team(_seat), do: :team2

  defp winner_team("team1"), do: :team1
  defp winner_team("team2"), do: :team2
  defp winner_team(_), do: nil

  defp hand_at(events, t), do: Enum.count(events, &(&1["e"] == "deal" and &1["t"] <= t))

  # The site event that opened this game in this player's browser.
  defp game_view(game_name, player_id, site_events) do
    Enum.find(site_events, fn e ->
      e.name == "game_view" and e.game_name == game_name and
        (player_id == :only_human or e.player_id == player_id)
    end)
  end

  defp visitor_for(game_name, player_id, site_events) do
    case game_view(game_name, player_id, site_events) do
      %{visitor_id: visitor_id} -> visitor_id
      nil -> nil
    end
  end

  defp device_for(game_name, player_id, data) do
    case game_view(game_name, player_id, data.site_events) do
      %{device: device} when is_binary(device) ->
        device

      _ ->
        case Enum.find(data.replays, &replay_of?(&1, game_name, player_id)) do
          %{device: device} -> device
          nil -> "unknown"
        end
    end
  end

  defp replay_of?(replay, game_name, player_id) do
    replay.game_name == game_name and is_binary(replay.device) and
      (player_id == :only_human or replay.player_id == player_id)
  end

  # How long each of this seat's own moves took: from the moment it became
  # their turn (the previous event; for discards, the kitty) to the move.
  # Approximate: animations the log doesn't record are included.
  defp think_times(events, seat) do
    events
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, i} ->
      if event["p"] == seat and event["e"] in @actions and event["b"] != true and i > 0 do
        start = turn_start(events, i, event["e"])
        [%{action: event["e"], hand: hand_at(events, event["t"]), ms: max(event["t"] - start, 0)}]
      else
        []
      end
    end)
  end

  defp turn_start(events, i, "discard") do
    events
    |> Enum.take(i)
    |> Enum.reverse()
    |> Enum.find_value(0, &(&1["e"] == "kitty" && &1["t"]))
  end

  # Presence events (join, leave, idle, ...) land between turns without
  # starting one.
  defp turn_start(events, i, _action) do
    events
    |> Enum.take(i)
    |> Enum.reverse()
    |> Enum.find(&(&1["e"] not in @presence_events))
    |> case do
      %{"e" => "trick", "t" => t} -> t + @trick_pause_ms
      %{"t" => t} -> t
      nil -> 0
    end
  end

  ## Funnel

  defp funnel(site_events, seats) do
    by_visitor = Enum.group_by(site_events, & &1.visitor_id)
    seats_by_visitor = seats |> Enum.filter(& &1.visitor_id) |> Enum.group_by(& &1.visitor_id)

    steps = [
      {"Opened any page", fn _v, events -> Enum.any?(events, &(&1.name == "page_view")) end},
      {"Opened /play", fn _v, events -> Enum.any?(events, &play_page?/1) end},
      {"Joined the queue or added a bot",
       fn _v, events -> Enum.any?(events, &(&1.name in ["queue_join", "bot_added"])) end},
      {"Opened a game", fn _v, events -> Enum.any?(events, &(&1.name == "game_view")) end},
      {"Made a move themselves",
       fn v, _events -> Enum.any?(Map.get(seats_by_visitor, v, []), &(&1.moves > 0)) end},
      {"Played a whole game",
       fn v, _events ->
         Enum.any?(Map.get(seats_by_visitor, v, []), &(&1.stayed and &1.ended == "finished"))
       end},
      {"Played 2+ games",
       fn _v, events ->
         events
         |> Enum.filter(&(&1.name == "game_view"))
         |> Enum.uniq_by(& &1.game_name)
         |> length() >= 2
       end},
      {"Came back on another day",
       fn _v, events ->
         events |> Enum.map(&NaiveDateTime.to_date(&1.inserted_at)) |> Enum.uniq() |> length() >=
           2
       end}
    ]

    total = map_size(by_visitor)

    Enum.map(steps, fn {label, reached?} ->
      count = Enum.count(by_visitor, fn {v, events} -> reached?.(v, events) end)
      %{label: label, count: count, pct: pct(count, total)}
    end)
  end

  defp play_page?(%{name: "page_view", path: "/play" <> _}), do: true
  defp play_page?(_event), do: false

  ## Visitors

  defp visitors_by_day(site_events, first_seen) do
    site_events
    |> Enum.group_by(&NaiveDateTime.to_date(&1.inserted_at))
    |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
    |> Enum.map(fn {date, events} ->
      visitors = events |> Enum.map(& &1.visitor_id) |> Enum.uniq()

      new = Enum.count(visitors, &new_on?(first_seen[&1], date))

      games = events |> Enum.filter(&(&1.name == "game_view")) |> Enum.uniq_by(& &1.game_name)

      %{
        date: date,
        visitors: length(visitors),
        new: new,
        returning: length(visitors) - new,
        games_opened: length(games)
      }
    end)
  end

  # A visitor first seen on or after `date` (no earlier record) is new.
  defp new_on?(nil, _date), do: true
  defp new_on?(first, date), do: Date.compare(NaiveDateTime.to_date(first), date) != :lt

  defp referrers(site_events) do
    site_events
    |> Enum.group_by(& &1.visitor_id)
    |> Enum.map(fn {_v, events} ->
      first = Enum.find(events, &(&1.name == "page_view"))
      source = (first && first.referrer) || "(direct / unknown)"
      {source, Enum.any?(events, &(&1.name == "game_view"))}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {source, played} ->
      %{
        source: source,
        visitors: length(played),
        played: Enum.count(played, & &1),
        pct: pct(Enum.count(played, & &1), length(played))
      }
    end)
    |> Enum.sort_by(& &1.visitors, :desc)
  end

  ## Devices

  defp devices(seats) do
    seats
    |> Enum.group_by(& &1.device)
    |> Enum.map(fn {device, group} ->
      plays =
        for s <- group, t <- s.think_times, t.action == "play", do: t.ms

      %{
        device: device,
        games: length(group),
        left_first_hand: pct(Enum.count(group, &left_first_hand?/1), length(group)),
        stayed: pct(Enum.count(group, & &1.stayed), length(group)),
        median_play_ms: median(plays)
      }
    end)
    |> Enum.sort_by(& &1.games, :desc)
  end

  defp viewports(site_events) do
    site_events
    |> Enum.filter(&(&1.name == "page_view" and &1.viewport_w))
    |> Enum.uniq_by(& &1.visitor_id)
    |> Enum.group_by(&viewport_bucket/1)
    |> Enum.map(fn {bucket, events} -> %{bucket: bucket, visitors: length(events)} end)
    |> Enum.sort_by(& &1.visitors, :desc)
  end

  defp viewport_bucket(%{viewport_w: w}) when w < 400, do: "under 400px wide (small phone)"
  defp viewport_bucket(%{viewport_w: w}) when w < 600, do: "400-599px (phone)"
  defp viewport_bucket(%{viewport_w: w}) when w < 1024, do: "600-1023px (tablet / narrow window)"
  defp viewport_bucket(_event), do: "1024px+ (laptop / desktop)"

  ## Leaving games

  defp left_first_hand?(seat), do: not seat.stayed and seat.left_hand <= 1

  defp early_exits(seats) do
    seats
    |> Enum.filter(&left_first_hand?/1)
    |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})
    |> Enum.take(50)
  end

  # What the game was waiting on when players gave up, by hand.
  defp exit_points(seats) do
    left = Enum.reject(seats, & &1.stayed)

    left
    |> Enum.group_by(&{min(&1.left_hand, 4), &1.moves == 0, &1.left_before})
    |> Enum.map(fn {{hand, no_moves, before}, group} ->
      %{
        hand: if(hand >= 4, do: "4+", else: Integer.to_string(hand)),
        never_moved: no_moves,
        waiting_on: before,
        count: length(group)
      }
    end)
    |> Enum.sort_by(&{&1.hand, -&1.count})
    |> then(&%{total_games: length(seats), left: length(left), rows: &1})
  end

  ## Decision times

  defp decision_times(seats) do
    for s <- seats, t <- s.think_times do
      {t.action, if(t.hand == 1, do: "first hand", else: "later hands"), s.device, t.ms}
    end
    |> Enum.group_by(fn {action, hand, device, _} -> {action, hand, device} end, &elem(&1, 3))
    |> Enum.map(fn {{action, hand, device}, times} ->
      %{
        action: action,
        hand: hand,
        device: device,
        n: length(times),
        median_ms: median(times),
        p90_ms: percentile(times, 0.9)
      }
    end)
    |> Enum.sort_by(&{Enum.find_index(@actions, fn a -> a == &1.action end), &1.hand, &1.device})
  end

  ## Bots

  defp bots(seats) do
    finished = Enum.filter(seats, &(&1.stayed and &1.ended == "finished" and &1.human_count == 1))

    by_week =
      finished
      |> Enum.group_by(&Date.beginning_of_week(NaiveDateTime.to_date(&1.at)))
      |> Enum.sort_by(&elem(&1, 0), {:desc, Date})
      |> Enum.map(fn {week, group} ->
        %{week: week, games: length(group), won: pct(Enum.count(group, & &1.won), length(group))}
      end)

    %{
      games: length(finished),
      won: pct(Enum.count(finished, & &1.won), length(finished)),
      by_week: by_week
    }
  end

  ## Learn page

  defp learn(site_events, seats) do
    learners =
      site_events
      |> Enum.filter(&(&1.name == "page_view" and &1.path == "/learn"))
      |> MapSet.new(& &1.visitor_id)

    tracked = Enum.filter(seats, & &1.visitor_id)
    {saw, didnt} = Enum.split_with(tracked, &MapSet.member?(learners, &1.visitor_id))

    for {label, group} <- [{"Visited /learn", saw}, {"Never visited /learn", didnt}] do
      %{
        label: label,
        games: length(group),
        left_first_hand: pct(Enum.count(group, &left_first_hand?/1), length(group)),
        stayed: pct(Enum.count(group, & &1.stayed), length(group))
      }
    end
  end

  ## Queue

  defp queue(site_events, games) do
    public_joins =
      Enum.filter(site_events, &(&1.name == "queue_join" and &1.data["queue"] == "public"))

    leaves = Enum.filter(site_events, &(&1.name == "queue_leave"))
    waits = leaves |> Enum.map(& &1.data["waited_ms"]) |> Enum.filter(&is_integer/1)

    %{
      public_joins: length(public_joins),
      joined_empty_queue: Enum.count(public_joins, &(&1.data["waiting"] == 0)),
      bots_added: Enum.count(site_events, &(&1.name == "bot_added")),
      private_created: Enum.count(site_events, &(&1.name == "private_created")),
      left_queue: length(leaves),
      median_wait_before_leaving_ms: median(waits),
      games: length(games),
      games_with_2_plus_humans: Enum.count(games, &((&1.log.human_count || 1) >= 2))
    }
  end

  ## Helpers

  defp tracking_since([]), do: nil
  defp tracking_since([first | _]), do: first.inserted_at

  defp pct(_n, 0), do: nil
  defp pct(n, total), do: round(n * 100 / total)

  defp median(list), do: percentile(list, 0.5)

  defp percentile([], _p), do: nil

  defp percentile(list, p) do
    sorted = Enum.sort(list)
    Enum.at(sorted, min(round(p * (length(sorted) - 1)), length(sorted) - 1))
  end
end
