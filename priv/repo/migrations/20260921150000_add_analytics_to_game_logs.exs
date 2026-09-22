defmodule Website45sV3.Repo.Migrations.AddAnalyticsToGameLogs do
  use Ecto.Migration

  def change do
    # Per-game summary columns are queryable without touching the blob; the
    # full event log lives gzipped in `events` and is nulled by the pruner
    # once it ages out (the summary row stays).
    alter table(:game_logs) do
      add :game_name, :string
      add :ended, :string
      add :duration_ms, :integer
      add :hands, :integer
      add :human_count, :integer
      add :winner, :string
      add :team1_score, :integer
      add :team2_score, :integer
      add :event_count, :integer
      add :events, :binary
    end

    create index(:game_logs, [:game_name])
    create index(:game_logs, [:inserted_at])

    # One browser session at one table. Chunks are gzipped rrweb event
    # arrays in arrival order; deleting the replay cascades to them.
    create table(:replays) do
      add :game_name, :string, null: false
      add :player_id, :string, null: false
      add :display_name, :string
      add :device, :string
      add :viewport_w, :integer
      add :viewport_h, :integer
      add :bytes, :bigint, null: false, default: 0
      add :chunk_count, :integer, null: false, default: 0
      timestamps()
    end

    create index(:replays, [:game_name])
    create index(:replays, [:inserted_at])

    create table(:replay_chunks) do
      add :replay_id, references(:replays, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :data, :binary, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:replay_chunks, [:replay_id, :seq])

    # The clicks from each recording, on the server's clock, so a game's
    # timeline is a query rather than a decode of every replay.
    create table(:replay_clicks) do
      add :replay_id, references(:replays, on_delete: :delete_all), null: false
      add :at_ms, :bigint, null: false
      add :data, :map, null: false, default: %{}
    end

    create index(:replay_clicks, [:replay_id])
  end
end
