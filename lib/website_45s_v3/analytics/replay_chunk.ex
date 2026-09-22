defmodule Website45sV3.Analytics.ReplayChunk do
  @moduledoc """
  A gzipped JSON array of rrweb events, one of the ordered pieces of a
  `Website45sV3.Analytics.Replay`.
  """
  use Ecto.Schema

  schema "replay_chunks" do
    belongs_to :replay, Website45sV3.Analytics.Replay
    field :seq, :integer
    field :data, :binary
    timestamps(updated_at: false)
  end
end
