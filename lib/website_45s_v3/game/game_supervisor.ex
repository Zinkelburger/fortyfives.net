defmodule Website45sV3.Game.GameSupervisor do
  @moduledoc """
  Supervises running games. Games are `:temporary` so a crashing game is not
  restarted (players are notified instead), and starting games here keeps
  them unlinked from the queue managers — a crashing game can no longer take
  down the matchmaking processes and every other running game with them.
  """
  use DynamicSupervisor

  # Global cap on concurrent games, mirroring BotSupervisor's bot cap:
  # scripted queue joins must not be able to spawn unbounded game processes.
  # Overridable through the :max_concurrent_games application env.
  @default_max_games 50

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_game(game_name, player_tuples) do
    if game_count() >= max_games() do
      {:error, :too_many_games}
    else
      DynamicSupervisor.start_child(
        __MODULE__,
        {Website45sV3.Game.GameController, {game_name, player_tuples}}
      )
    end
  end

  def game_count do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  defp max_games do
    Application.get_env(:website_45s_v3, :max_concurrent_games, @default_max_games)
  end
end
