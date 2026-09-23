defmodule Website45sV3.Analytics.SiteEvent do
  @moduledoc """
  One thing a visitor did outside the game table: a page view, joining or
  leaving the queue, adding a bot, opening a game. Recorded from connected
  LiveViews only (see `Website45sV3Web.SiteTracking`), so crawlers that do
  not run JavaScript never appear.

  Names: `"page_view"`, `"queue_join"`, `"queue_leave"`, `"bot_added"`,
  `"private_created"`, `"game_view"`, `"abandon"`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @names ~w(page_view queue_join queue_leave bot_added private_created game_view abandon)

  schema "site_events" do
    field :visitor_id, :string
    field :player_id, :string
    field :name, :string
    field :path, :string
    field :game_name, :string
    # Host only ("google.com"), never the full URL.
    field :referrer, :string
    # "mobile" | "desktop"
    field :device, :string
    field :viewport_w, :integer
    field :viewport_h, :integer
    field :data, :map, default: %{}
    timestamps(updated_at: false)
  end

  def names, do: @names

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :visitor_id,
      :player_id,
      :name,
      :path,
      :game_name,
      :referrer,
      :device,
      :viewport_w,
      :viewport_h,
      :data
    ])
    |> validate_required([:visitor_id, :name])
    |> validate_inclusion(:name, @names)
    |> validate_inclusion(:device, ["mobile", "desktop"])
    |> validate_length(:visitor_id, max: 64)
    |> validate_length(:player_id, max: 64)
    |> validate_length(:path, max: 200)
    |> validate_length(:game_name, max: 64)
    |> validate_length(:referrer, max: 100)
    |> validate_number(:viewport_w, greater_than: 0, less_than: 20_000)
    |> validate_number(:viewport_h, greater_than: 0, less_than: 20_000)
  end
end
