defmodule Website45sV3.Repo.Migrations.AddGoogleUidToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :google_uid, :string
    end

    create unique_index(:users, [:google_uid])
  end
end
