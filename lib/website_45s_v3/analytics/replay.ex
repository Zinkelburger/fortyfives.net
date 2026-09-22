defmodule Website45sV3.Analytics.Replay do
  @moduledoc """
  One browser's rrweb recording of one game (see `Website45sV3.Analytics`).

  `bytes` (stored size: gzipped chunks plus click rows), `raw_bytes`
  (decoded size) and `chunk_count` are maintained on append so the pruner and the
  admin list never have to scan `replay_chunks`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "replays" do
    field :game_name, :string
    # The seat identity from the session, never an IP or account.
    field :player_id, :string
    field :display_name, :string
    # "mobile" | "desktop"
    field :device, :string
    field :viewport_w, :integer
    field :viewport_h, :integer
    field :bytes, :integer, default: 0
    field :raw_bytes, :integer, default: 0
    field :chunk_count, :integer, default: 0
    has_many :chunks, Website45sV3.Analytics.ReplayChunk
    has_many :clicks, Website45sV3.Analytics.ReplayClick
    timestamps()
  end

  def changeset(replay, attrs) do
    replay
    |> cast(attrs, [:game_name, :player_id, :display_name, :device, :viewport_w, :viewport_h])
    |> validate_required([:game_name, :player_id])
    |> validate_inclusion(:device, ["mobile", "desktop"])
    |> validate_length(:game_name, max: 64)
    |> validate_length(:player_id, max: 64)
    |> validate_length(:display_name, max: 64)
    |> validate_number(:viewport_w, greater_than: 0, less_than: 20_000)
    |> validate_number(:viewport_h, greater_than: 0, less_than: 20_000)
  end
end
