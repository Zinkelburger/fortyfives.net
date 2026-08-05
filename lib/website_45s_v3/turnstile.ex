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
      If the site key is set but the secret is missing, verification is
      skipped with a warning so a misconfigured deploy doesn't lock every
      user out of signup/login.
  """

  require Logger

  @siteverify_url "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  def site_key, do: Application.get_env(:website_45s_v3, :turnstile_site_key)

  defp secret, do: Application.get_env(:website_45s_v3, :turnstile_secret)

  @doc """
  Verifies a Turnstile token against Cloudflare's siteverify endpoint.

  Returns `:ok` when the token is accepted (or when Turnstile is not
  configured), `{:error, :turnstile_failed}` otherwise.
  """
  def verify(token, remote_ip \\ nil) do
    cond do
      is_nil(site_key()) ->
        :ok

      secret() in [nil, ""] ->
        Logger.warning("TURNSTILE_SECRET is not set — skipping Turnstile verification")
        :ok

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
  Best-effort client IP for a Plug connection, preferring proxy headers.
  """
  def client_ip(%Plug.Conn{} = conn) do
    headers =
      Enum.flat_map(["cf-connecting-ip", "x-forwarded-for"], fn name ->
        Enum.map(Plug.Conn.get_req_header(conn, name), &{name, &1})
      end)

    from_headers(headers) || format_ip(conn.remote_ip)
  end

  @doc """
  Best-effort client IP from LiveView `connect_info` (`:x_headers` and
  `:peer_data`). Either argument may be `nil` during static render.
  """
  def client_ip(x_headers, peer_data) do
    from_headers(x_headers || []) ||
      case peer_data do
        %{address: address} -> format_ip(address)
        _ -> nil
      end
  end

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
end
