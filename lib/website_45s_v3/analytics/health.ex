defmodule Website45sV3.Analytics.Health do
  @moduledoc """
  Did anyone run into trouble? A summary of the last `days` from what the
  database already records, for a quick check after a deploy or any time:

      bin/website_45s_v3 rpc "IO.puts(Website45sV3.Analytics.Health.text(days: 7))"

  The pruner also logs the last day's summary once a day ("Daily health").

  * games — how they ended (`crash` should be 0), and *no-show seats*: a
    human seated at a table whose page never connected to it. Bots play
    those seats, so the other players had a partner who never moved. Each
    one is worth a look at the logs around that game's start.
  * queue — joins, and departures by reason ("disconnect" includes tabs
    the queue dropped because they closed without leaving).
  * accounts — sign-ups, email confirmations, and sign-ins that are still
    active (signing out deletes its token, so this undercounts a little).

  Errors that never reach the database (a LiveView crash, a failed email)
  are only in the logs: `docker logs fortyfives-web-1 2>&1 | grep -E
  "\\[error\\]|not connected"`.
  """

  import Ecto.Query

  alias Website45sV3.Accounts.User
  alias Website45sV3.Accounts.UserToken
  alias Website45sV3.Analytics.SiteEvent
  alias Website45sV3.Game.GameEvents
  alias Website45sV3.Game.GameLog
  alias Website45sV3.Repo

  @doc """
  The summary as a map. Options: `days:` (default 1), `now:`.
  """
  def report(opts \\ []) do
    days = Keyword.get(opts, :days, 1)
    now = Keyword.get(opts, :now, NaiveDateTime.utc_now())
    since = NaiveDateTime.add(now, -days, :day)

    %{
      days: days,
      since: NaiveDateTime.truncate(since, :second),
      visitors: visitors(since),
      games: games(since),
      queue: queue(since),
      accounts: accounts(since)
    }
  end

  @doc """
  `report/1` as a few lines of text.
  """
  def text(opts \\ []), do: format(report(opts))

  @doc false
  def format(report) do
    %{games: games, queue: queue, accounts: accounts} = report

    no_shows =
      case games.no_show_games do
        [] -> ""
        names -> " (" <> Enum.join(names, ", ") <> ")"
      end

    """
    Health for the last #{report.days} day(s), since #{report.since} UTC
      visitors: #{report.visitors}
      games: #{games.total} (finished #{games.finished}, abandoned #{games.abandoned}, crashed #{games.crash})
      no-show seats: #{games.no_show_seats} of #{games.human_seats} human seats#{no_shows}
      queue: #{queue.joins} joins, departures: #{departures(queue.departures)}
      accounts: #{accounts.signups} sign-ups (#{accounts.google_signups} Google), #{accounts.confirmed} confirmed by email, #{accounts.sign_ins} sign-ins still active
    """
  end

  defp departures(by_reason) when by_reason == %{}, do: "none"

  defp departures(by_reason) do
    by_reason
    |> Enum.sort_by(fn {_reason, n} -> -n end)
    |> Enum.map_join(", ", fn {reason, n} -> "#{reason} #{n}" end)
  end

  defp visitors(since) do
    Repo.one(
      from(e in SiteEvent, where: e.inserted_at >= ^since, select: count(e.visitor_id, :distinct))
    )
  end

  defp games(since) do
    logs =
      from(g in GameLog,
        where: g.inserted_at >= ^since,
        select: map(g, [:game_name, :ended, :events])
      )
      |> Repo.all()

    seats = Enum.flat_map(logs, &human_seats/1)
    no_shows = Enum.reject(seats, & &1.connected)

    %{
      total: length(logs),
      finished: Enum.count(logs, &(&1.ended == "finished")),
      abandoned: Enum.count(logs, &(&1.ended == "abandoned")),
      crash: Enum.count(logs, &(&1.ended == "crash")),
      human_seats: length(seats),
      no_show_seats: length(no_shows),
      no_show_games: no_shows |> Enum.map(& &1.game_name) |> Enum.uniq() |> Enum.take(10)
    }
  end

  # A seat connected if the game logged a join for it. Logs whose events were
  # pruned or cannot be read say nothing either way.
  defp human_seats(%{game_name: game_name, events: events}) do
    case GameEvents.decode(events) do
      {:ok, document} ->
        joined =
          for %{"e" => "join", "p" => seat} <- document["events"] || [],
              into: MapSet.new(),
              do: seat

        for %{"bot" => false, "seat" => seat} <- document["players"] || [] do
          %{game_name: game_name, connected: MapSet.member?(joined, seat)}
        end

      _ ->
        []
    end
  end

  defp queue(since) do
    events =
      from(e in SiteEvent,
        where: e.inserted_at >= ^since and e.name in ["queue_join", "queue_leave"],
        select: {e.name, e.data}
      )
      |> Repo.all()

    departures =
      for {"queue_leave", data} <- events, reduce: %{} do
        acc -> Map.update(acc, (data || %{})["reason"] || "unknown", 1, &(&1 + 1))
      end

    %{joins: Enum.count(events, &(elem(&1, 0) == "queue_join")), departures: departures}
  end

  defp accounts(since) do
    signups = from(u in User, where: u.inserted_at >= ^since)

    %{
      signups: Repo.aggregate(signups, :count),
      google_signups: Repo.aggregate(where(signups, [u], not is_nil(u.google_uid)), :count),
      confirmed:
        Repo.aggregate(
          from(u in User,
            where: is_nil(u.google_uid) and u.confirmed_at >= ^since
          ),
          :count
        ),
      sign_ins:
        Repo.aggregate(
          from(t in UserToken, where: t.context == "session" and t.inserted_at >= ^since),
          :count
        )
    }
  end
end
