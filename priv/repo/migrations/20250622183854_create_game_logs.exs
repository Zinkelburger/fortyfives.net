defmodule Website45sV3.Repo.Migrations.CreateGameLogs do
  use Ecto.Migration

  def change do
    create table(:game_logs) do
      add :player_usernames, {:array, :string}, null: false
      timestamps()
    end
  end
end
