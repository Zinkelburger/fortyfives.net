defmodule Website45sV3.AuthHealthTest do
  use ExUnit.Case, async: false

  alias Website45sV3.AuthHealth
  alias Website45sV3.Turnstile
  alias Website45sV3.TurnstileStub

  defmodule GoogleStub do
    @moduledoc false
    def post(url, _headers, body, _timeout_ms) do
      %{responder: responder, test_pid: test_pid} =
        Application.fetch_env!(:website_45s_v3, :google_stub)

      send(test_pid, {:google_token, url, URI.decode_query(body)})
      responder.()
    end
  end

  setup do
    previous_google = Application.fetch_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
      client_id: "client-id",
      client_secret: "client-secret"
    )

    Application.put_env(:website_45s_v3, :auth_health_http_client, GoogleStub)
    Turnstile.reset_last_outcome()
    AuthHealth.clear_cache()

    on_exit(fn ->
      case previous_google do
        {:ok, value} -> Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, value)
        :error -> Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      end

      Application.delete_env(:website_45s_v3, :auth_health_http_client)
      Application.delete_env(:website_45s_v3, :google_stub)
      Turnstile.reset_last_outcome()
      AuthHealth.clear_cache()
    end)
  end

  defp google_answers(status, body) do
    Application.put_env(:website_45s_v3, :google_stub, %{
      responder: fn -> {:ok, status, Jason.encode!(body)} end,
      test_pid: self()
    })
  end

  defp valid_turnstile_secret do
    TurnstileStub.with_siteverify(fn _params ->
      {:ok, 200,
       Jason.encode!(%{"success" => false, "error-codes" => ["invalid-input-response"]})}
    end)
  end

  test "all checks pass with working credentials" do
    valid_turnstile_secret()
    google_answers(400, %{"error" => "invalid_grant"})

    assert {:ok, checks} = AuthHealth.status()

    assert checks == %{
             "turnstile_secret" => "ok",
             "turnstile_verifications" => "ok",
             "google_oauth" => "ok"
           }

    assert_receive {:google_token, "https://oauth2.googleapis.com/token", params}
    assert params["client_id"] == "client-id"
    assert params["client_secret"] == "client-secret"
    assert params["grant_type"] == "authorization_code"
  end

  test "a rejected Google client fails" do
    valid_turnstile_secret()
    google_answers(401, %{"error" => "invalid_client"})

    assert {:fail, %{"google_oauth" => "fail: invalid_client"}} = AuthHealth.status()
  end

  test "missing Google credentials fail without calling Google" do
    valid_turnstile_secret()
    google_answers(400, %{"error" => "invalid_grant"})

    Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth,
      client_id: "",
      client_secret: nil
    )

    assert {:fail, %{"google_oauth" => "fail: client id or secret not set"}} = AuthHealth.status()
    refute_receive {:google_token, _url, _params}
  end

  test "a real token rejected for the secret fails until one verifies" do
    valid_turnstile_secret()
    google_answers(400, %{"error" => "invalid_grant"})

    TurnstileStub.with_siteverify(fn _params ->
      {:ok, 200, Jason.encode!(%{"success" => false, "error-codes" => ["invalid-input-secret"]})}
    end)

    Turnstile.verify("visitor-token")

    assert {:fail, %{"turnstile_verifications" => "fail: invalid-input-secret since " <> _}} =
             AuthHealth.status()
  end

  test "external checks are cached" do
    valid_turnstile_secret()
    google_answers(400, %{"error" => "invalid_grant"})

    assert {:ok, _checks} = AuthHealth.status()
    assert_receive {:google_token, _url, _params}
    assert_receive {:siteverify, _params}

    assert {:ok, _checks} = AuthHealth.status()
    refute_receive {:google_token, _url, _params}
    refute_receive {:siteverify, _params}
  end
end
