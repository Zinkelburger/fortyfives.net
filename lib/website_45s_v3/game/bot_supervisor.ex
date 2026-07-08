defmodule Website45sV3.Game.BotSupervisor do
  use DynamicSupervisor

  # Global cap so the 🤖 button can't be used to spawn unbounded processes.
  @max_bots 12

  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_bot(display_name) when is_binary(display_name) do
    start_child({:public, display_name})
  end

  def start_private_bot(private_id, display_name) do
    start_child({:private, private_id, display_name})
  end

  def bot_count do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  def at_capacity? do
    bot_count() >= @max_bots
  end

  defp start_child(arg) do
    if at_capacity?() do
      {:error, :too_many_bots}
    else
      DynamicSupervisor.start_child(__MODULE__, {Website45sV3.Game.BotPlayerServer, arg})
    end
  end
end
