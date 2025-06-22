defmodule Website45sV3.Game.GameLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "game_logs" do
    field :player_usernames, {:array, :string}
    timestamps()
  end

  def changeset(game_log, attrs) do
    game_log
    |> cast(attrs, [:player_usernames])
    |> validate_required([:player_usernames])
  end
end
