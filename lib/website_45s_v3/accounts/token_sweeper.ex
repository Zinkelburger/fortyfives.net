defmodule Website45sV3.Accounts.TokenSweeper do
  @moduledoc """
  Periodically deletes expired rows from `users_tokens`.

  Tokens are already refused once they are older than their context allows
  (see `Website45sV3.Accounts.UserToken`), so nothing depends on this sweep for
  correctness; without it the table simply grows by one row per login and per
  email sent, forever.

  Add to the supervision tree after the repo:

      Website45sV3.Accounts.TokenSweeper

  Options: `:interval_ms` (default 6 hours) and `:initial_delay_ms` (default
  1 minute, so a boot storm is not also a delete storm).
  """

  use GenServer

  require Logger

  alias Website45sV3.Accounts

  @default_interval_ms 6 * 60 * 60 * 1000
  @default_initial_delay_ms 60 * 1000

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def last_purged(server \\ __MODULE__), do: GenServer.call(server, :last_purged)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      last_purged: nil
    }

    initial_delay_ms = Keyword.get(opts, :initial_delay_ms, @default_initial_delay_ms)
    Process.send_after(self(), :sweep, initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    count = Accounts.purge_expired_tokens()

    if count > 0 do
      Logger.info("TokenSweeper purged #{count} expired user token(s)")
    end

    Process.send_after(self(), :sweep, state.interval_ms)
    {:noreply, %{state | last_purged: count}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:last_purged, _from, state), do: {:reply, state.last_purged, state}
end
