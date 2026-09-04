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

  # `requester` is the session user_id that asked for the bot; it is stored
  # in the bot's presence metadata so the lobby can cap bots per requester.
  def start_bot(display_name, requester \\ nil) when is_binary(display_name) do
    start_child({:public, display_name, requester})
  end

  def start_private_bot(private_id, display_name, requester \\ nil) do
    start_child({:private, private_id, display_name, requester})
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
      case DynamicSupervisor.start_child(__MODULE__, {Website45sV3.Game.BotPlayerServer, arg}) do
        {:ok, pid} ->
          {:ok, pid}

        # The bot refused to start because the queue would not take it (the
        # lobby is gone, or it is rate limited). Unwrap the supervisor's
        # shutdown tuple so callers see the reason itself.
        {:error, {:shutdown, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
