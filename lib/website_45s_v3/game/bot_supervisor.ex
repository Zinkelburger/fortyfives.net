defmodule Website45sV3.Game.BotSupervisor do
  use DynamicSupervisor

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_bot(display_name) do
    DynamicSupervisor.start_child(__MODULE__, {Website45sV3.Game.BotPlayerServer, display_name})
  end
end
