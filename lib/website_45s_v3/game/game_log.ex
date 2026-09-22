defmodule Website45sV3.Game.GameLog do
  @moduledoc """
  A record of a finished game.

  The summary columns (who played, how it ended, scores) are plain and
  queryable. `events` is the full gzipped JSON event log built by
  `Website45sV3.Game.GameEvents`; it is nulled by the analytics pruner once
  it ages out, so it may be `nil` on older rows.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "game_logs" do
    field :player_usernames, {:array, :string}
    field :game_name, :string
    # "finished" | "abandoned" | "crash"
    field :ended, :string
    field :duration_ms, :integer
    field :hands, :integer
    field :human_count, :integer
    # "team1" | "team2" | nil
    field :winner, :string
    field :team1_score, :integer
    field :team2_score, :integer
    field :event_count, :integer
    field :events, :binary
    timestamps()
  end

  @summary_fields [
    :game_name,
    :ended,
    :duration_ms,
    :hands,
    :human_count,
    :winner,
    :team1_score,
    :team2_score,
    :event_count,
    :events
  ]

  def changeset(game_log, attrs) do
    game_log
    |> cast(attrs, [:player_usernames | @summary_fields])
    |> validate_required([:player_usernames])
    |> validate_inclusion(:ended, ["finished", "abandoned", "crash"])
    |> validate_inclusion(:winner, ["team1", "team2"])
  end
end
