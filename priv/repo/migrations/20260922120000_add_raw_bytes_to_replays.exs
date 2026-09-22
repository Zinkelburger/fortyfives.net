defmodule Website45sV3.Repo.Migrations.AddRawBytesToReplays do
  use Ecto.Migration

  def change do
    # Uncompressed size of a recording. The compressed `bytes` alone cannot
    # bound what the admin player has to decode: a batch of repetitive JSON
    # gzips a thousandfold.
    alter table(:replays) do
      add :raw_bytes, :bigint, null: false, default: 0
    end

    # Replays per seat per game are capped when a recording starts.
    create index(:replays, [:game_name, :player_id])
  end
end
