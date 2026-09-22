defmodule Website45sV3.AnalyticsTest do
  use Website45sV3.DataCase, async: true

  alias Website45sV3.Analytics
  alias Website45sV3.Analytics.Replay
  alias Website45sV3.Analytics.Timeline
  alias Website45sV3.Game.GameEvents
  alias Website45sV3.Game.GameLog

  # A minimal valid rrweb batch.
  @batch ~s([{"type":3,"timestamp":1}])

  defp start_replay!(attrs \\ %{}) do
    {:ok, replay} =
      Analytics.start_replay(
        Map.merge(
          %{game_name: "G1", player_id: "p1", display_name: "Ann", device: "desktop"},
          attrs
        )
      )

    replay
  end

  defp backdate(schema, id, days) do
    at = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_naive()
    Repo.update_all(from(r in schema, where: r.id == ^id), set: [inserted_at: at])
  end

  describe "replays" do
    test "chunks are stored gzipped, counted, and played back as one array" do
      replay = start_replay!()

      {:ok, replay} =
        Analytics.append_chunk(replay, 0, ~s([{"type":4,"timestamp":1},{"type":2,"timestamp":2}]))

      {:ok, replay} = Analytics.append_chunk(replay, 1, "[]")
      {:ok, replay} = Analytics.append_chunk(replay, 2, ~s([{"type":3,"timestamp":3}]))

      assert replay.chunk_count == 3
      assert replay.bytes > 0
      assert replay.raw_bytes > 0

      assert Jason.decode!(Analytics.replay_events_json(replay)) ==
               [
                 %{"type" => 4, "timestamp" => 1},
                 %{"type" => 2, "timestamp" => 2},
                 %{"type" => 3, "timestamp" => 3}
               ]
    end

    test "anything but an array of rrweb events is refused" do
      replay = start_replay!()

      for json <- [
            "[1]",
            "{}",
            "not json",
            ~s([{"type":3}]),
            ~s([{"type":99,"timestamp":1}]),
            ~s([{"type":3,"timestamp":1}]"<script>")
          ] do
        assert {:error, :invalid_events} = Analytics.append_chunk(replay, 0, json)
      end

      assert Analytics.get_replay!(replay.id).chunk_count == 0
    end

    test "decoded size is capped, however well the batches compress" do
      replay = start_replay!()
      # ~1 MB of padding that gzips to a few KB.
      padding = String.duplicate(" ", 999_000)
      batch = "[" <> padding <> ~s({"type":3,"timestamp":1}])

      replay =
        Enum.reduce_while(0..60, replay, fn seq, replay ->
          case Analytics.append_chunk(replay, seq, batch) do
            {:ok, replay} -> {:cont, replay}
            {:error, :replay_too_large} -> {:halt, replay}
          end
        end)

      assert replay.raw_bytes <= 50_000_000
      assert replay.chunk_count < 60
    end

    test "click rows count toward the stored size" do
      replay = start_replay!()
      {:ok, without} = Analytics.append_chunk(replay, 0, @batch)

      clicks = for i <- 1..100, do: %{at_ms: i, data: %{"el" => String.duplicate("x", 120)}}
      {:ok, with_clicks} = Analytics.append_chunk(without, 1, @batch, clicks)

      assert with_clicks.bytes - without.bytes > 100 * 120
    end

    test "a seat can only open so many recordings at one table" do
      for _ <- 1..5, do: start_replay!()

      assert {:error, :too_many_replays} =
               Analytics.start_replay(%{game_name: "G1", player_id: "p1", device: "desktop"})

      assert {:ok, _} =
               Analytics.start_replay(%{game_name: "G1", player_id: "p2", device: "desktop"})
    end

    test "opening a recording while storage is over the cap deletes the oldest first" do
      oldest = start_replay!(%{player_id: "old"})
      {:ok, oldest} = Analytics.append_chunk(oldest, 0, @batch)
      backdate(Replay, oldest.id, 1)

      Application.put_env(:website_45s_v3, Website45sV3.Analytics, replay_max_bytes: 1)
      on_exit(fn -> Application.delete_env(:website_45s_v3, Website45sV3.Analytics) end)

      assert {:ok, _} = Analytics.start_replay(%{game_name: "G1", player_id: "new"})
      assert Repo.get(Replay, oldest.id) == nil
    end

    test "a duplicate sequence number is refused" do
      replay = start_replay!()
      {:ok, replay} = Analytics.append_chunk(replay, 0, @batch)
      assert {:error, :duplicate_seq} = Analytics.append_chunk(replay, 0, @batch)
      assert Analytics.get_replay!(replay.id).chunk_count == 1
    end

    test "oversized batches are refused" do
      replay = start_replay!()
      huge = "[" <> String.duplicate("1,", 600_000) <> "1]"
      assert {:error, :chunk_too_large} = Analytics.append_chunk(replay, 0, huge)
    end

    test "recording metadata is validated" do
      assert {:error, changeset} =
               Analytics.start_replay(%{game_name: "G", player_id: "p", device: "toaster"})

      assert %{device: _} = errors_on(changeset)
    end

    test "a batch for a replay the pruner removed is refused, not raised" do
      replay = start_replay!()
      Repo.delete!(replay)

      assert {:error, :replay_gone} = Analytics.append_chunk(replay, 0, @batch)
    end

    test "clicks are stored with the batch and listed per game, oldest first" do
      ann = start_replay!(%{display_name: "Ann"})
      bob = start_replay!(%{player_id: "p2", display_name: "Bob"})
      other = start_replay!(%{game_name: "G2", player_id: "p3", display_name: "Zed"})

      {:ok, _} = Analytics.append_chunk(ann, 0, @batch, [%{at_ms: 2_000, data: %{"el" => "a"}}])
      {:ok, _} = Analytics.append_chunk(bob, 0, @batch, [%{at_ms: 1_000, data: %{"el" => "b"}}])
      {:ok, _} = Analytics.append_chunk(other, 0, @batch, [%{at_ms: 500, data: %{"el" => "z"}}])

      assert Analytics.list_clicks("G1") == [
               {"Bob", %{"el" => "b"}, 1_000},
               {"Ann", %{"el" => "a"}, 2_000}
             ]

      assert Analytics.list_clicks(nil) == []

      # A batch that is refused stores none of its clicks either.
      assert {:error, :duplicate_seq} =
               Analytics.append_chunk(ann, 0, @batch, [%{at_ms: 3_000, data: %{}}])

      assert length(Analytics.list_clicks("G1")) == 2

      Repo.delete!(ann)
      assert [{"Bob", _, _}] = Analytics.list_clicks("G1")
    end
  end

  describe "clicks_from_client/3" do
    test "shifts click times by the browser's clock skew" do
      # The browser thinks it is 40s earlier than the server.
      client_now = 1_000_000
      server_now = 1_040_000

      assert [%{at_ms: 1_030_000}, %{at_ms: 1_039_000}] =
               Analytics.clicks_from_client(
                 [%{"ts" => 990_000, "el" => "a"}, %{"ts" => 999_000, "el" => "b"}],
                 client_now,
                 server_now
               )
    end

    test "keeps only the known keys, truncates strings and caps the batch" do
      [%{data: data}] =
        Analytics.clicks_from_client(
          [
            %{
              "ts" => 1,
              "el" => String.duplicate("x", 500),
              "phx" => "confirm_bid",
              "dead" => true,
              "turn" => "yes",
              "phase" => 7,
              "evil" => "<script>"
            }
          ],
          0,
          0
        )

      assert Map.keys(data) == ["dead", "el", "phx"]
      assert String.length(data["el"]) == 120

      many = for i <- 1..1_000, do: %{"ts" => i}
      assert length(Analytics.clicks_from_client(many, 0, 0)) == 500
    end

    test "garbage from the client is an empty list" do
      assert Analytics.clicks_from_client(nil, nil) == []
      assert Analytics.clicks_from_client("[]", 5) == []
      assert Analytics.clicks_from_client([%{"el" => "no timestamp"}, "x", 3], 5, 5) == []
      assert Analytics.clicks_from_client([%{"ts" => 1}], "now", 5) == []
    end
  end

  describe "prune/1" do
    test "deletes replays past their retention and their chunks" do
      old = start_replay!()
      {:ok, _} = Analytics.append_chunk(old, 0, @batch)
      backdate(Replay, old.id, Analytics.config(:replay_days) + 1)
      fresh = start_replay!()

      assert %{replays_expired: 1} = Analytics.prune()
      assert Repo.get(Replay, old.id) == nil
      assert Repo.get(Replay, fresh.id)
      assert Repo.aggregate(Website45sV3.Analytics.ReplayChunk, :count) == 0
    end

    test "deletes the oldest replays until storage is under the cap" do
      oldest = start_replay!()
      {:ok, _} = Analytics.append_chunk(oldest, 0, @batch)
      backdate(Replay, oldest.id, 2)
      newer = start_replay!()
      {:ok, newer} = Analytics.append_chunk(newer, 0, @batch)
      backdate(Replay, newer.id, 1)

      # A cap of exactly one replay: the oldest goes, the newer one fits.
      Application.put_env(:website_45s_v3, Website45sV3.Analytics, replay_max_bytes: newer.bytes)
      on_exit(fn -> Application.delete_env(:website_45s_v3, Website45sV3.Analytics) end)

      assert %{replays_over_cap: 1} = Analytics.prune()
      assert Repo.get(Replay, oldest.id) == nil
      assert Repo.get(Replay, newer.id)
    end

    test "drops old game event blobs but keeps the summary row" do
      {:ok, log} =
        %GameLog{}
        |> GameLog.changeset(%{player_usernames: ["a"], ended: "finished", events: "x"})
        |> Repo.insert()

      backdate(GameLog, log.id, Analytics.config(:game_events_days) + 1)

      assert %{game_events_expired: 1} = Analytics.prune()
      assert %GameLog{events: nil, ended: "finished"} = Repo.get(GameLog, log.id)
    end
  end

  describe "Timeline" do
    test "renders game events and replay clicks in time order with gaps" do
      started_at = ~U[2026-09-21 12:00:00Z]

      document = %{
        "game" => "G1",
        "started_at" => DateTime.to_iso8601(started_at),
        "ended" => "finished",
        "winner" => "team1",
        "players" => [
          %{"seat" => 0, "name" => "Ann", "bot" => false},
          %{"seat" => 1, "name" => "Bot1", "bot" => true},
          %{"seat" => 2, "name" => "Bot2", "bot" => true},
          %{"seat" => 3, "name" => "Bot3", "bot" => true}
        ],
        "events" => [
          %{"t" => 0, "e" => "deal", "hand" => 1, "dealer" => 3, "hands" => [["1_hearts"]]},
          %{"t" => 1200, "e" => "bid", "p" => 1, "v" => 0, "b" => true},
          %{"t" => 31_000, "e" => "idle", "p" => 0, "phase" => "Bidding"},
          %{"t" => 32_000, "e" => "bid", "p" => 0, "v" => 15, "s" => "hearts", "b" => true},
          %{"t" => 40_000, "e" => "end", "r" => "normal"}
        ]
      }

      click = %{
        "el" => "img#hand-card-5_hearts",
        "card" => "5_hearts",
        "dead" => true,
        "phase" => "Bidding",
        "turn" => true
      }

      stored = [{"Ann", click, DateTime.to_unix(started_at, :millisecond) + 20_000}]
      clicks = Timeline.on_game_clock(stored, started_at)
      assert [{"Ann", ^click, 20_000}] = clicks
      assert Timeline.on_game_clock(stored, nil) == []

      lines = Timeline.lines(document, clicks)

      assert lines == [
               "00:00.0  Hand 1 dealt by Bot3 (bot). Ann: 1_hearts",
               "00:01.2  Bot1 (bot) passes",
               "00:20.0  [+18.8s] Ann clicked img#hand-card-5_hearts (card 5_hearts) DEAD CLICK during Bidding on their turn",
               "00:31.0  [+11.0s] Ann timed out in Bidding; a bot takes over",
               "00:32.0  Ann bids 15 hearts (a bot played for them)",
               "00:40.0  [+8.0s] Game ended (normal)"
             ]

      assert Timeline.text(document, clicks) =~ "winner: team1"
    end
  end

  describe "GameEvents" do
    test "finalize/2 round-trips through decode/1" do
      state =
        Map.merge(GameEvents.init(), %{
          game_name: "G9",
          player_ids: ["a", "b", "c", "d"],
          player_map: %{"a" => "Ann", "b" => "Bot1", "c" => "Cy", "d" => "Bot3"},
          seat_bots: MapSet.new(["b", "d"]),
          phase: "Final Scoring",
          team_scores: %{team1: 125, team2: 40},
          winning_team: :team1,
          team_1_history: ["a", "b", "c"]
        })

      state = GameEvents.log(state, "bid", %{p: 0, v: 20, s: :hearts, b: false})
      attrs = GameEvents.finalize(state, :normal)

      assert attrs.ended == "finished"
      assert attrs.winner == "team1"
      assert attrs.hands == 3
      assert attrs.human_count == 2
      assert attrs.event_count == 1

      assert {:ok, document} = GameEvents.decode(attrs.events)
      assert [%{"e" => "bid", "s" => "hearts", "v" => 20, "t" => t}] = document["events"]
      assert is_integer(t)
      assert Enum.map(document["players"], & &1["bot"]) == [false, true, false, true]
    end

    test "crashes and unfinished games are labelled" do
      base =
        Map.merge(GameEvents.init(), %{
          game_name: "G",
          player_ids: ["a", "b", "c", "d"],
          player_map: %{},
          seat_bots: MapSet.new(),
          phase: "Playing",
          team_scores: %{team1: 0, team2: 0},
          team_1_history: []
        })

      assert %{ended: "abandoned", winner: nil} = GameEvents.finalize(base, :normal)
      assert %{ended: "crash"} = GameEvents.finalize(base, {:error, :boom})
    end

    test "the winner is the team the game awarded, not the higher score" do
      # Both teams crossed 120 in the same hand: the bidders (team 2) win
      # under the rules even though team 1 has more points.
      state =
        Map.merge(GameEvents.init(), %{
          game_name: "G",
          player_ids: ["a", "b", "c", "d"],
          player_map: %{},
          seat_bots: MapSet.new(),
          phase: "Final Scoring",
          team_scores: %{team1: 125, team2: 120},
          winning_team: :team2,
          team_1_history: ["x"]
        })

      attrs = GameEvents.finalize(state, :normal)
      assert attrs.winner == "team2"
      assert {:ok, %{"winner" => "team2"}} = GameEvents.decode(attrs.events)

      # A game that reached the final screen without a recorded decision
      # (older state) has no winner rather than a guessed one.
      assert %{winner: nil} = GameEvents.finalize(Map.delete(state, :winning_team), :normal)
    end
  end
end
