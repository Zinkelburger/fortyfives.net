defmodule Website45sV3.Analytics.Timeline do
  @moduledoc """
  Renders a game's event log (see `Website45sV3.Game.GameEvents`) as
  chronological plain-text lines, optionally merged with the click events
  from the players' browser replays.

  This is the form meant for reading and for handing to a model: one line
  per thing that happened, stamped `mm:ss.s`, with the gap since the
  previous line called out when it is long enough to suggest hesitation.

      00:04.2  Alice bids 20 hearts
      00:41.0  [+36.8s] Bob timed out in Bidding; a bot takes over
      00:43.5  Bob clicked img#hand-card-5_hearts (card 5_hearts) DEAD CLICK
  """

  @hesitation_ms 5_000

  @doc """
  `document` is a decoded game log; `clicks` are `{name, click_map, at_ms}`
  tuples as returned by `on_game_clock/2`. Returns a list of strings.
  """
  def lines(document, clicks \\ []) do
    players = document["players"] || []
    names = Map.new(players, &{&1["seat"], player_label(&1)})
    bot_seats = for %{"bot" => true, "seat" => seat} <- players, into: MapSet.new(), do: seat

    game_lines =
      document["events"]
      |> List.wrap()
      |> Enum.map(fn event -> {event["t"], describe(event, names, bot_seats)} end)

    click_lines =
      Enum.map(clicks, fn {name, click, at_ms} -> {at_ms, describe_click(name, click)} end)

    (game_lines ++ click_lines)
    |> Enum.reject(fn {_t, text} -> is_nil(text) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> with_gaps()
    |> Enum.map(fn {t, gap, text} -> format_time(t) <> "  " <> gap <> text end)
  end

  def text(document, clicks \\ []) do
    header = [
      "Game #{document["game"]} started #{document["started_at"]}, ended: #{document["ended"]}" <>
        if(document["winner"], do: ", winner: #{document["winner"]}", else: ""),
      "Seats: " <>
        Enum.map_join(document["players"] || [], "; ", fn p ->
          "#{p["seat"]} = #{player_label(p)} (team #{rem(p["seat"], 2) + 1})"
        end),
      ""
    ]

    Enum.join(header ++ lines(document, clicks), "\n")
  end

  @doc """
  Puts stored clicks (`{name, click, epoch_ms}`, as
  `Website45sV3.Analytics.list_clicks/1` returns them) on the game's clock:
  `{name, click, ms_since_game_start}`. Without a start time they cannot
  be placed, so none.
  """
  def on_game_clock(clicks, %DateTime{} = started_at) do
    start_ms = DateTime.to_unix(started_at, :millisecond)
    Enum.map(clicks, fn {name, click, at_ms} -> {name, click, at_ms - start_ms} end)
  end

  def on_game_clock(_clicks, nil), do: []

  defp with_gaps(entries) do
    entries
    |> Enum.map_reduce(nil, fn {t, text}, previous ->
      gap =
        if previous && t - previous >= @hesitation_ms,
          do: "[+#{Float.round((t - previous) / 1000, 1)}s] ",
          else: ""

      {{t, gap, text}, t}
    end)
    |> elem(0)
  end

  defp player_label(%{"name" => name, "bot" => true}), do: name <> " (bot)"
  defp player_label(%{"name" => name}), do: name

  defp name(names, seat), do: Map.get(names, seat, "seat #{seat}")

  # Actions carry `"b" => true` when bot logic chose them. For a seat that is
  # a bot anyway the label already says so; for a human it means they had
  # idled out or left, which is the interesting case.
  defp describe(%{"b" => true, "p" => seat} = e, names, bot_seats) do
    case describe(e, names) do
      nil ->
        nil

      text ->
        if MapSet.member?(bot_seats, seat), do: text, else: text <> " (a bot played for them)"
    end
  end

  defp describe(e, names, _bot_seats), do: describe(e, names)

  defp describe(%{"e" => "deal"} = e, names) do
    "Hand #{e["hand"]} dealt by #{name(names, e["dealer"])}. " <> hands(e["hands"], names)
  end

  defp describe(%{"e" => "bid", "v" => 0} = e, names), do: "#{name(names, e["p"])} passes"

  defp describe(%{"e" => "bid"} = e, names),
    do: "#{name(names, e["p"])} bids #{e["v"]} #{e["s"]}"

  defp describe(%{"e" => "kitty"} = e, names) do
    "#{name(names, e["p"])} wins the bidding at #{e["v"]} #{e["s"]}; kitty: #{cards(e["c"])}"
  end

  defp describe(%{"e" => "discard"} = e, names),
    do: "#{name(names, e["p"])} keeps #{cards(e["keep"])}"

  defp describe(%{"e" => "play_start"} = e, names),
    do: "Play starts. " <> hands(e["hands"], names)

  defp describe(%{"e" => "play"} = e, names),
    do: "#{name(names, e["p"])} plays #{e["c"]}"

  defp describe(%{"e" => "trick"} = e, names),
    do: "Trick #{e["n"]} won by #{name(names, e["w"])} with #{e["c"]}"

  defp describe(%{"e" => "score"} = e, _names) do
    "Hand #{e["hand"]} scored: team 1 #{signed(e["d1"])} -> #{e["t1"]}, " <>
      "team 2 #{signed(e["d2"])} -> #{e["t2"]}" <>
      if(e["win"], do: ". #{e["win"]} wins the game", else: "")
  end

  defp describe(%{"e" => "idle"} = e, names),
    do: "#{name(names, e["p"])} timed out in #{e["phase"]}; a bot takes over"

  defp describe(%{"e" => "resume"} = e, names),
    do: "#{name(names, e["p"])} takes back control"

  defp describe(%{"e" => "abandon"} = e, names),
    do: "#{name(names, e["p"])} left the game for good during #{e["phase"]}"

  defp describe(%{"e" => "leave"} = e, names), do: "#{name(names, e["p"])} disconnected"
  defp describe(%{"e" => "join"} = e, names), do: "#{name(names, e["p"])} (re)connected"
  defp describe(%{"e" => "end"} = e, _names), do: "Game ended (#{e["r"]})"
  defp describe(%{"e" => other}, _names), do: other
  defp describe(_event, _names), do: nil

  defp describe_click(name, click) do
    parts =
      [
        "#{name} clicked #{click["el"]}",
        click["phx"] && "-> #{click["phx"]}",
        click["card"] && "(card #{click["card"]})",
        click["text"] && click["text"] != "" && ~s("#{click["text"]}"),
        click["dead"] && "DEAD CLICK",
        click["phase"] && "during #{click["phase"]}",
        click["turn"] && "on their turn",
        click["auto"] && "while a bot was playing for them"
      ]
      |> Enum.filter(&is_binary/1)

    Enum.join(parts, " ")
  end

  defp hands(hands, names) do
    hands
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map_join("; ", fn {hand, seat} -> "#{name(names, seat)}: #{cards(hand)}" end)
  end

  defp cards(cards), do: cards |> List.wrap() |> Enum.join(" ")

  defp signed(n) when is_integer(n) and n > 0, do: "+#{n}"
  defp signed(n), do: to_string(n)

  defp format_time(ms) when is_integer(ms) do
    total_tenths = div(max(ms, 0), 100)
    minutes = div(total_tenths, 600)
    seconds = rem(total_tenths, 600) / 10

    :io_lib.format("~2..0B:~4.1.0f", [minutes, seconds]) |> IO.iodata_to_binary()
  end

  defp format_time(_), do: "??:??.?"
end
