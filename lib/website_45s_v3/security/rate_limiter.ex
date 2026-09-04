defmodule Website45sV3.Security.RateLimiter do
  @moduledoc """
  In-memory admission limiter for authentication, outbound mail and anonymous
  game traffic.

  Counters live in a public ETS table and are incremented with
  `:ets.update_counter/4`, so the hot path never serializes through a process.
  The owning GenServer exists only to hold the table and sweep expired buckets.

  Windows are *fixed*: the current wall-clock time is divided into
  `window_ms`-wide buckets and the bucket index is part of the key, which makes
  each hit a single atomic operation and bounds memory to one row per active
  key per window. The trade-off versus a sliding window is that a caller can
  spend a full budget at the end of one bucket and another at the start of the
  next; budgets are sized with that in mind.

  Limits are per node. The public edge should retain its own distributed limits
  when the application is deployed on more than one node.
  """

  use GenServer

  @table __MODULE__

  @default_login [window_ms: 15 * 60 * 1000, max_ip: 30, max_account: 8]
  @default_queue [window_ms: 60 * 60 * 1000, max_ip: 40, max_create_ip: 10]
  @default_registration [window_ms: 60 * 60 * 1000, max_ip: 5]
  @default_email [window_ms: 60 * 60 * 1000, max_ip: 20, max_address: 5]

  @defaults [
    login: @default_login,
    queue: @default_queue,
    registration: @default_registration,
    email: @default_email
  ]

  @sweep_interval_ms 5 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  ## Login

  @doc """
  Records a login attempt from `remote_ip` and refuses it once the per-network
  budget is spent.
  """
  def check_login_ip(remote_ip) do
    config = limits(:login)
    hit([{{:login_ip, network_key(remote_ip)}, config[:max_ip]}], config[:window_ms])
  end

  @doc """
  Reports whether an account has spent its failed-attempt budget, *without*
  consuming any of it. Callers must not use this to refuse a request that
  carries correct credentials — see `Website45sV3Web.UserSessionController` —
  or a third party can lock a known account out at will.
  """
  def login_account_exhausted?(identifier) do
    config = limits(:login)

    exhausted?(
      {:login_account, account_key(identifier)},
      config[:max_account],
      config[:window_ms]
    )
  end

  @doc """
  Consumes one failed-attempt slot for an account.
  """
  def record_login_failure(identifier) do
    config = limits(:login)
    hit([{{:login_account, account_key(identifier)}, config[:max_account]}], config[:window_ms])
  end

  @doc """
  Clears an account's failed-attempt budget after a successful login.
  """
  def reset_login_account(identifier) do
    forget({:login_account, account_key(identifier)})
  end

  ## Registration and outbound mail

  @doc """
  Reports whether a network has created its allowance of accounts, *without*
  consuming any of it, so a caller can refuse before doing the work.
  """
  def registration_exhausted?(remote_ip) do
    config = limits(:registration)

    exhausted?(
      {:registration_ip, network_key(remote_ip)},
      config[:max_ip],
      config[:window_ms]
    )
  end

  @doc """
  Records an account actually created from `remote_ip`.

  Charged on success only: a rejected changeset costs the visitor nothing, so
  someone fumbling the signup form cannot lock themselves out of registering.
  What this budget exists to cap is created accounts and the confirmation mail
  they send, and only a success produces either.
  """
  def record_registration(remote_ip) do
    config = limits(:registration)
    hit([{{:registration_ip, network_key(remote_ip)}, config[:max_ip]}], config[:window_ms])
  end

  @doc """
  Records a request that causes an unauthenticated email to be sent (password
  reset, confirmation resend). Budgeted per network *and* per destination
  address so neither a single sender nor a single victim's inbox can be
  flooded. Both counters are consumed even when one of them is what refuses
  the request.
  """
  def check_email_send(remote_ip, address) do
    config = limits(:email)

    hit(
      [
        {{:email_ip, network_key(remote_ip)}, config[:max_ip]},
        {{:email_address, account_key(address)}, config[:max_address]}
      ],
      config[:window_ms]
    )
  end

  ## Queues

  def check_queue_join(remote_ip) do
    config = limits(:queue)
    hit([{{:queue_ip, network_key(remote_ip)}, config[:max_ip]}], config[:window_ms])
  end

  def check_private_queue_create(remote_ip) do
    config = limits(:queue)

    hit(
      [{{:private_queue_create_network, network_key(remote_ip)}, config[:max_create_ip]}],
      config[:window_ms]
    )
  end

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  ## Server

  @impl true
  def init(state) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true,
      decentralized_counters: true
    ])

    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Rows carry their own absolute expiry, so scopes with different window
    # lengths can be swept in one pass.
    now = now_ms()

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  # Consumes one slot against every key and refuses when any of them is over
  # budget. A key we could not build (an IP we could not determine, a blank
  # identifier) is dropped, so the remaining dimensions still apply — an
  # unknown client sending password resets is still capped per destination
  # address. Only when *nothing* is left to charge does this fail closed.
  # Callers that would rather admit unknown clients check for nil themselves.
  defp hit(keys, window_ms) when is_integer(window_ms) and window_ms > 0 do
    case valid_keys(keys) do
      [] ->
        {:error, :rate_limited}

      keys ->
        now = now_ms()
        bucket = Integer.floor_div(now, window_ms)
        expires_at = (bucket + 1) * window_ms

        over? =
          Enum.reduce(keys, false, fn {key, limit}, over? ->
            count =
              :ets.update_counter(
                @table,
                {key, bucket},
                {2, 1},
                {{key, bucket}, 0, expires_at}
              )

            over? or count > limit
          end)

        if over?, do: {:error, :rate_limited}, else: :ok
    end
  end

  # Unlike `hit/2` this is a read, not an admission decision, so an absent or
  # unusable key answers "not exhausted" rather than failing closed: a request
  # that never had an account to charge has spent nothing, and answering `true`
  # would report it to the user as throttling.
  defp exhausted?({_scope, nil}, _limit, _window_ms), do: false

  defp exhausted?(key, limit, window_ms)
       when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    bucket = Integer.floor_div(now_ms(), window_ms)

    case :ets.lookup(@table, {key, bucket}) do
      [{_full_key, count, _expires_at}] -> count >= limit
      [] -> false
    end
  end

  defp exhausted?(_key, _limit, _window_ms), do: false

  defp forget({_scope, nil}), do: :ok

  defp forget(key) do
    :ets.match_delete(@table, {{key, :_}, :_, :_})
    :ok
  end

  defp valid_keys(keys) do
    Enum.reject(keys, fn {{_scope, key}, limit} ->
      is_nil(key) or not is_integer(limit) or limit < 1
    end)
  end

  # A configured scope is merged over the defaults so a partial override (say,
  # only `max_ip`) cannot leave `window_ms` or a sibling budget nil.
  defp limits(scope) do
    defaults = Keyword.fetch!(@defaults, scope)

    configured =
      :website_45s_v3
      |> Application.get_env(:security_rate_limits, [])
      |> Keyword.get(scope, [])

    Keyword.merge(defaults, configured)
  end

  defp account_key(identifier) when is_binary(identifier) do
    case String.trim(identifier) do
      "" -> nil
      trimmed -> :crypto.hash(:sha256, String.downcase(trimmed))
    end
  end

  defp account_key(identifier) when not is_nil(identifier) do
    identifier
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp account_key(_), do: nil

  # Group IPv6 clients by /64 so rotating privacy addresses can neither bypass
  # a budget nor grow the table one row per address. IPv4 clients, and opaque
  # fallback keys such as "session:<id>", keep their individual key.
  defp network_key(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      # An IPv4-mapped address is an IPv4 client; collapsing it to a /64 would
      # put every such client in one bucket.
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, _a, _b} = address} -> Website45sV3.Turnstile.unmap(address)
      {:ok, {a, b, c, d, _e, _f, _g, _h}} -> {:ipv6_64, a, b, c, d}
      {:ok, {_a, _b, _c, _d} = address} -> address
      {:error, _reason} -> opaque_key(value)
    end
  end

  defp network_key(_), do: nil

  defp opaque_key(value) when is_binary(value) and byte_size(value) > 0, do: value
  defp opaque_key(_), do: nil

  defp now_ms, do: System.system_time(:millisecond)

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
