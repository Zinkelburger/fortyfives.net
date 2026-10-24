defmodule Website45sV3.Repo.Migrations.AddUsernamePendingToUsers do
  use Ecto.Migration

  def change do
    # Google sign-ups get a random player_xxxxxxx name and are offered once
    # to pick their own (/users/welcome); true until they save or skip.
    alter table(:users) do
      add :username_pending, :boolean, null: false, default: false
    end

    # Google accounts that never left their generated name are offered too.
    execute(
      "UPDATE users SET username_pending = 1 WHERE google_uid IS NOT NULL AND username GLOB 'player_*'",
      ""
    )
  end
end
