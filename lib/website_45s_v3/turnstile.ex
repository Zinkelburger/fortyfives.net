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
  """

  require Logger

  @siteverify_url "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  def site_key, do: Application.get_env(:website_45s_v3, :turnstile_site_key)

  defp secret, do: Application.get_env(:website_45s_v3, :turnstile_secret)

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

    request =
      Finch.build(
        :post,
        @siteverify_url,
        [{"content-type", "application/x-www-form-urlencoded"}],
        URI.encode_query(params)
      )

    with {:ok, %Finch.Response{status: 200, body: body}} <-
           Finch.request(request, Website45sV3.Finch),
         {:ok, %{"success" => true}} <- Jason.decode(body) do
      :ok
    else
      {:ok, %{"error-codes" => codes}} ->
        Logger.warning("Turnstile verification failed: #{inspect(codes)}")
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
