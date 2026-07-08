defmodule Website45sV3.Game.GameSupervisor do
  @moduledoc """
  Supervises running games. Games are `:temporary` so a crashing game is not
  restarted (players are notified instead), and starting games here keeps
  them unlinked from the queue managers — a crashing game can no longer take
  down the matchmaking processes and every other running game with them.
  """
  use DynamicSupervisor

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_game(game_name, player_tuples) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Website45sV3.Game.GameController, {game_name, player_tuples}}
    )
  end
end
