defmodule Website45sV3.Analytics.ReplayClick do
  @moduledoc """
  One click a player made during a `Website45sV3.Analytics.Replay`, kept
  apart from the rrweb stream so the admin timeline can list a game's clicks
  without decoding megabytes of recording.

  `at_ms` is epoch milliseconds on the server's clock (see
  `Website45sV3.Analytics.clicks_from_client/3`); `data` is what the
  SessionRecorder hook observed: the element, the card, whether the click
  did anything, and the phase it happened in.
  """
  use Ecto.Schema

  schema "replay_clicks" do
    belongs_to :replay, Website45sV3.Analytics.Replay
    field :at_ms, :integer
    field :data, :map
  end
end
