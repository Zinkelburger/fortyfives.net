defmodule Website45sV3.AuthHealth do
  @moduledoc """
  Whether sign-in can work in this environment, for `GET /healthz/auth` and
  the scheduled live check (`python/live_check.py`).

  Checks:

    * `turnstile_secret` — Cloudflare accepts the secret (dummy token).
    * `turnstile_verifications` — the latest real verification did not fail
      on a server-side configuration error such as a secret that belongs to
      another widget. Visitors find this before any synthetic check can,
      since a browser driven by a script is shown an interactive challenge.
    * `google_oauth` — Google accepts the OAuth client id and secret: a code
      exchange with a made-up code answers `invalid_grant`, while a wrong
      client or secret answers `invalid_client`.

  The two checks that call out are cached for `@ttl_ms`, so the public
  endpoint cannot be used to make this server hammer Cloudflare or Google.
  """

  use GenServer

  alias Website45sV3.Turnstile

  @ttl_ms :timer.minutes(5)
  @google_token_url "https://oauth2.googleapis.com/token"
  @request_timeout_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns `{:ok | :fail, checks}` where `checks` maps each check name to
  `"ok"`, `"disabled"` or `"fail: <reason>"`.
  """
  def status(server \\ __MODULE__) do
    external = GenServer.call(server, :external, 15_000)
    checks = Map.put(external, "turnstile_verifications", verifications())

    overall =
      if Enum.any?(checks, fn {_name, result} -> String.starts_with?(result, "fail") end),
        do: :fail,
        else: :ok

    {overall, checks}
  end

  @doc false
  def clear_cache(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call(:external, _from, {at, checks} = state) do
    if System.monotonic_time(:millisecond) - at < @ttl_ms do
      {:reply, checks, state}
    else
      handle_call(:external, nil, nil)
    end
  end

  def handle_call(:external, _from, nil) do
    checks = %{
      "turnstile_secret" => describe(Turnstile.check_secret()),
      "google_oauth" => describe(check_google())
    }

    {:reply, checks, {System.monotonic_time(:millisecond), checks}}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, nil}

  defp verifications do
    case Turnstile.last_outcome() do
      {{:config_error, codes}, at} ->
        "fail: #{Enum.join(codes, ",")} since #{DateTime.to_iso8601(at)}"

      _ ->
        "ok"
    end
  end

  defp describe(:ok), do: "ok"
  defp describe(:disabled), do: "disabled"
  defp describe({:error, reason}), do: "fail: #{reason}"

  @doc false
  def check_google do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, [])
    client_id = config[:client_id]
    client_secret = config[:client_secret]

    if Enum.any?([client_id, client_secret], &(&1 in [nil, ""])) do
      {:error, "client id or secret not set"}
    else
      body =
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "code" => "healthz-auth-check",
          "redirect_uri" => Website45sV3Web.Endpoint.url() <> "/auth/google/callback",
          "client_id" => client_id,
          "client_secret" => client_secret
        })

      headers = [{"content-type", "application/x-www-form-urlencoded"}]

      case http_client().post(@google_token_url, headers, body, @request_timeout_ms) do
        {:ok, _status, body} -> google_result(Jason.decode(body))
        {:error, reason} -> {:error, "token endpoint #{inspect(reason)}"}
      end
    end
  end

  defp google_result({:ok, %{"error" => "invalid_grant"}}), do: :ok
  defp google_result({:ok, %{"error" => error}}), do: {:error, error}
  defp google_result(_other), do: {:error, "unexpected token endpoint response"}

  defp http_client do
    Application.get_env(:website_45s_v3, :auth_health_http_client, Turnstile.FinchClient)
  end
end
