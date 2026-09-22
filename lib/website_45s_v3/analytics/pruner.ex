defmodule Website45sV3.Analytics.Pruner do
  @moduledoc """
  Runs `Website45sV3.Analytics.prune/0` on a schedule so replay storage and
  game event logs stay bounded (see the retention config there).

  Options: `:interval_ms` (default 24 hours) and `:initial_delay_ms`
  (default 5 minutes).
  """

  use GenServer

  require Logger

  alias Website45sV3.Analytics

  @default_interval_ms 24 * 60 * 60 * 1000
  @default_initial_delay_ms 5 * 60 * 1000

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)}

    Process.send_after(
      self(),
      :prune,
      Keyword.get(opts, :initial_delay_ms, @default_initial_delay_ms)
    )

    {:ok, state}
  end

  @impl true
  def handle_info(:prune, state) do
    result = Analytics.prune()

    if Enum.any?(result, fn {_k, v} -> v > 0 end) do
      Logger.info("Analytics pruner: #{inspect(result)}")
    end

    Process.send_after(self(), :prune, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
