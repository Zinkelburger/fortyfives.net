defmodule Website45sV3.Turnstile do
  @moduledoc """
  Server-side verification of Cloudflare Turnstile tokens.

  The widget is rendered with `Website45sV3Web.CoreComponents.turnstile/1`;
  handlers call `verify/2` with the `cf-turnstile-response` form param (and
  the client IP when available) before running their normal logic.

  Configuration:

    * `:turnstile_site_key` — public site key, set per environment. `nil`
      disables both the widget and verification entirely (test env).
    * `:turnstile_secret` — siteverify secret. In production it comes from
      the `TURNSTILE_SECRET` environment variable via `config/runtime.exs`.
      Production refuses to start without it. Verification fails closed if a
      site key is configured without a secret in any other environment.
    * `:turnstile_hostnames` — hostnames a token may have been solved on.
      Defaults to `#{inspect(["fortyfives.net", "www.fortyfives.net", "localhost"])}`.
      A token minted for any other site is refused even if Cloudflare accepts
      it, so a leaked secret cannot be paired with a widget elsewhere.
    * `:turnstile_http_client` — module implementing `post/4`; defaults to
      `Website45sV3.Turnstile.FinchClient`. Tests swap in a stub.

  Besides `success`, the siteverify response's `hostname` and `action` are
  checked. Cloudflare's documented testing keys answer with
  `hostname: "example.com"`, no `action`, and `metadata.result_with_testing_key`
  set, so those two checks are skipped for such responses (dev only; a real
  secret never produces that flag).
  """

  require Logger

  @siteverify_url "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  # Must match `data-action` on the widget in
  # `Website45sV3Web.CoreComponents.turnstile/1`.
  @expected_action "turnstile-spin-v2"

  @default_hostnames ["fortyfives.net", "www.fortyfives.net", "localhost"]

  @request_timeout_ms 5_000

  defmodule FinchClient do
    @moduledoc false

    @doc """
    POSTs a form body and returns `{:ok, status, body}` or `{:error, reason}`.
    Both the pool checkout and the response wait are bounded so a slow
    Cloudflare cannot hold a request process indefinitely.
    """
    def post(url, headers, body, timeout_ms) do
      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, Website45sV3.Finch,
             pool_timeout: timeout_ms,
             receive_timeout: timeout_ms
           ) do
        {:ok, %Finch.Response{status: status, body: body}} -> {:ok, status, body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def site_key, do: Application.get_env(:website_45s_v3, :turnstile_site_key)

  @doc false
  def expected_action, do: @expected_action

  @doc """
  Hostnames a Turnstile token may have been solved on.
  """
  def allowed_hostnames do
    Application.get_env(:website_45s_v3, :turnstile_hostnames, @default_hostnames)
  end

  defp secret, do: Application.get_env(:website_45s_v3, :turnstile_secret)

  defp http_client do
    Application.get_env(:website_45s_v3, :turnstile_http_client, FinchClient)
  end

  @doc """
  Verifies a Turnstile token against Cloudflare's siteverify endpoint.

  Returns `:ok` when the token is accepted, or when Turnstile is explicitly
  disabled by setting the site key to `nil`. Returns
  `{:error, :turnstile_failed}` otherwise.
  """
  def verify(token, remote_ip \\ nil) do
    cond do
      is_nil(site_key()) ->
        :ok

      secret() in [nil, ""] ->
        Logger.error("TURNSTILE_SECRET is not set — rejecting Turnstile verification")
        {:error, :turnstile_failed}

      true ->
        do_verify(token, remote_ip)
    end
  end

  defp do_verify(token, remote_ip) when is_binary(token) and token != "" do
    params = %{"secret" => secret(), "response" => token}
    params = if remote_ip, do: Map.put(params, "remoteip", remote_ip), else: params
    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    with {:ok, 200, body} <-
           http_client().post(
             @siteverify_url,
             headers,
             URI.encode_query(params),
             @request_timeout_ms
           ),
         {:ok, %{"success" => true} = response} <- Jason.decode(body),
         :ok <- check_hostname(response),
         :ok <- check_action(response) do
      :ok
    else
      {:ok, %{"error-codes" => codes}} ->
        Logger.warning("Turnstile verification failed: #{inspect(codes)}")
        {:error, :turnstile_failed}

      {:error, {:unexpected_hostname, hostname}} ->
        Logger.warning("Turnstile token was solved on unexpected host #{inspect(hostname)}")
        {:error, :turnstile_failed}

      {:error, {:unexpected_action, action}} ->
        Logger.warning("Turnstile token carried unexpected action #{inspect(action)}")
        {:error, :turnstile_failed}

      other ->
        Logger.warning("Turnstile siteverify request failed: #{inspect(other)}")
        {:error, :turnstile_failed}
    end
  end

  defp do_verify(_token, _remote_ip) do
    Logger.warning("Turnstile token missing from request")
    {:error, :turnstile_failed}
  end

  defp testing_key_response?(%{"metadata" => %{"result_with_testing_key" => true}}), do: true
  defp testing_key_response?(_response), do: false

  defp check_hostname(response) do
    hostname = response["hostname"]

    cond do
      testing_key_response?(response) -> :ok
      is_binary(hostname) and hostname in allowed_hostnames() -> :ok
      true -> {:error, {:unexpected_hostname, hostname}}
    end
  end

  defp check_action(response) do
    action = response["action"]

    cond do
      testing_key_response?(response) -> :ok
      action == @expected_action -> :ok
      true -> {:error, {:unexpected_action, action}}
    end
  end

  @doc """
  Best-effort client IP for a Plug connection. Forwarded headers are accepted
  only when the direct peer is a loopback or private-network proxy.
  """
  def client_ip(%Plug.Conn{} = conn) do
    peer = unmap(conn.remote_ip)

    if trusted_proxy?(peer) do
      headers =
        Enum.flat_map(["cf-connecting-ip", "x-forwarded-for"], fn name ->
          Enum.map(Plug.Conn.get_req_header(conn, name), &{name, &1})
        end)

      from_headers(headers) || format_ip(peer)
    else
      format_ip(peer)
    end
  end

  @doc """
  Best-effort client IP from LiveView `connect_info` (`:x_headers` and
  `:peer_data`). Either argument may be `nil` during static render.

  Note that Phoenix only puts `x-` prefixed headers in `:x_headers`, so on this
  path only `x-forwarded-for` can ever match — `nginx.conf` must keep setting
  it, not just `CF-Connecting-IP`.
  """
  def client_ip(x_headers, peer_data) do
    peer_address = if is_map(peer_data), do: unmap(Map.get(peer_data, :address))

    if trusted_proxy?(peer_address) do
      from_headers(x_headers || []) || format_ip(peer_address)
    else
      format_ip(peer_address)
    end
  end

  @doc """
  Rewrites an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) to its plain IPv4
  tuple, and passes anything else through.

  The production endpoint binds `::`, so a dual-stack listener hands us every
  IPv4 peer — including the reverse proxy — in mapped form. Without this the
  proxy is not recognised as trusted, forwarded headers are dropped, and every
  visitor collapses onto a single rate-limit key.
  """
  def unmap({0, 0, 0, 0, 0, 0xFFFF, a, b}) do
    {Bitwise.bsr(a, 8), Bitwise.band(a, 0xFF), Bitwise.bsr(b, 8), Bitwise.band(b, 0xFF)}
  end

  def unmap(address), do: address

  defp from_headers(headers) do
    Enum.find_value(["cf-connecting-ip", "x-forwarded-for"], fn name ->
      case List.keyfind(headers, name, 0) do
        {_, value} -> value |> String.split(",") |> List.first() |> String.trim()
        nil -> nil
      end
    end)
  end

  defp format_ip(address) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, _} -> nil
      chars -> to_string(chars)
    end
  end

  defp format_ip(_), do: nil

  defp trusted_proxy?({127, _, _, _}), do: true
  defp trusted_proxy?({10, _, _, _}), do: true
  defp trusted_proxy?({192, 168, _, _}), do: true
  defp trusted_proxy?({172, second, _, _}) when second in 16..31, do: true
  defp trusted_proxy?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp trusted_proxy?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFE00) == 0xFC00,
    do: true

  defp trusted_proxy?(_), do: false
end
