defmodule Website45sV3.TurnstileStub do
  @moduledoc """
  Stand-in for `Website45sV3.Turnstile.FinchClient` so tests can script the
  siteverify response without touching the network.

  `with_siteverify/1` configures a site key and secret (so verification is
  live), installs this module as the HTTP client, and stores the given
  responder — a function receiving the decoded form params and returning
  `{:ok, status, body}` or `{:error, reason}` — until the test exits. Each
  request is also reported to the test process as `{:siteverify, params}`.
  """

  @keys [:turnstile_site_key, :turnstile_secret, :turnstile_http_client, :turnstile_stub]

  def post(_url, _headers, body, _timeout_ms) do
    params = URI.decode_query(body)

    %{responder: responder, test_pid: test_pid} =
      Application.fetch_env!(:website_45s_v3, :turnstile_stub)

    send(test_pid, {:siteverify, params})
    responder.(params)
  end

  @doc """
  A siteverify body Cloudflare would send for a token solved on `hostname`
  with the expected action, optionally overridden.
  """
  def success_body(overrides \\ %{}) do
    Map.merge(
      %{
        "success" => true,
        "hostname" => "fortyfives.net",
        "action" => Website45sV3.Turnstile.expected_action(),
        "error-codes" => []
      },
      overrides
    )
    |> Jason.encode!()
  end

  def with_siteverify(responder) when is_function(responder, 1) do
    previous = Enum.map(@keys, &{&1, Application.fetch_env(:website_45s_v3, &1)})

    Application.put_env(:website_45s_v3, :turnstile_site_key, "configured")
    Application.put_env(:website_45s_v3, :turnstile_secret, "test-secret")
    Application.put_env(:website_45s_v3, :turnstile_http_client, __MODULE__)

    Application.put_env(:website_45s_v3, :turnstile_stub, %{
      responder: responder,
      test_pid: self()
    })

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:website_45s_v3, key, value)
        {key, :error} -> Application.delete_env(:website_45s_v3, key)
      end)
    end)

    :ok
  end

  @doc """
  Configures a site key without a secret, which makes every verification
  fail closed. Handy for driving the `:turnstile_failed` branch of a handler.
  """
  def force_failure do
    previous_site_key = Application.fetch_env(:website_45s_v3, :turnstile_site_key)
    previous_secret = Application.fetch_env(:website_45s_v3, :turnstile_secret)

    Application.put_env(:website_45s_v3, :turnstile_site_key, "configured")
    Application.delete_env(:website_45s_v3, :turnstile_secret)

    ExUnit.Callbacks.on_exit(fn ->
      restore(:turnstile_site_key, previous_site_key)
      restore(:turnstile_secret, previous_secret)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:website_45s_v3, key, value)
  defp restore(key, :error), do: Application.delete_env(:website_45s_v3, key)
end
