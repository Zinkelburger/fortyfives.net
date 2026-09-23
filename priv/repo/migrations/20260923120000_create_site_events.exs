defmodule Website45sV3.Repo.Migrations.CreateSiteEvents do
  use Ecto.Migration

  def change do
    # Page views and lobby actions from connected LiveViews, for the visit
    # funnel on /admin/insights. `visitor_id` is a long-lived anonymous
    # cookie; `player_id` is the session's seat id, which joins a visitor to
    # their games and replays. No IPs, no user agents.
    create table(:site_events) do
      add :visitor_id, :string, null: false
      add :player_id, :string
      add :name, :string, null: false
      add :path, :string
      add :game_name, :string
      add :referrer, :string
      add :device, :string
      add :viewport_w, :integer
      add :viewport_h, :integer
      add :data, :map, null: false, default: %{}
      timestamps(updated_at: false)
    end

    create index(:site_events, [:inserted_at])
    create index(:site_events, [:visitor_id])
    create index(:site_events, [:game_name])
  end
end
