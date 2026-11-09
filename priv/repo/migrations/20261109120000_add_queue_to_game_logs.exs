defmodule Website45sV3.Repo.Migrations.AddQueueToGameLogs do
  use Ecto.Migration

  def change do
    # Which queue started the game ("public" | "private"), and for a private
    # game the first 8 characters of its lobby id, the same tag its lobby's
    # site events and log lines carry. Never the full id: that is the invite.
    # Rows from before this column are NULL (unknown), not "public".
    alter table(:game_logs) do
      add :queue, :string
      add :lobby, :string
    end
  end
end
