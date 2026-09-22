defmodule Website45sV3.TurnstileTest do
  use ExUnit.Case, async: false

  alias Website45sV3.Turnstile
  alias Website45sV3.TurnstileStub

  test "fails closed when a site key is configured without a secret" do
    TurnstileStub.force_failure()
    assert {:error, :turnstile_failed} = Turnstile.verify("token")
  end

  test "is a no-op when no site key is configured" do
    assert Application.get_env(:website_45s_v3, :turnstile_site_key) == nil
    assert :ok = Turnstile.verify(nil)
    assert :ok = Turnstile.verify("anything", "203.0.113.1")
  end

  describe "siteverify" do
    test "accepts a successful response for the expected host and action" do
      TurnstileStub.with_siteverify(fn _params -> {:ok, 200, TurnstileStub.success_body()} end)

      assert :ok = Turnstile.verify("solved-token", "203.0.113.9")
    end

    test "posts the secret, the token and the client IP" do
      TurnstileStub.with_siteverify(fn _params -> {:ok, 200, TurnstileStub.success_body()} end)

      Turnstile.verify("solved-token", "203.0.113.9")

      assert_receive {:siteverify, params}
      assert params["secret"] == "test-secret"
      assert params["response"] == "solved-token"
      assert params["remoteip"] == "203.0.113.9"
    end

    test "omits remoteip when the client IP is unknown" do
      TurnstileStub.with_siteverify(fn _params -> {:ok, 200, TurnstileStub.success_body()} end)

      Turnstile.verify("solved-token", nil)

      assert_receive {:siteverify, params}
      refute Map.has_key?(params, "remoteip")
    end

    test "refuses a missing or blank token without calling Cloudflare" do
      TurnstileStub.with_siteverify(fn _params -> flunk("should not be called") end)

      assert {:error, :turnstile_failed} = Turnstile.verify(nil)
      assert {:error, :turnstile_failed} = Turnstile.verify("")
      assert {:error, :turnstile_failed} = Turnstile.verify(["list"])
      refute_receive {:siteverify, _}
    end

    test "refuses when Cloudflare reports error codes" do
      TurnstileStub.with_siteverify(fn _params ->
        body = Jason.encode!(%{"success" => false, "error-codes" => ["timeout-or-duplicate"]})
        {:ok, 200, body}
      end)

      assert {:error, :turnstile_failed} = Turnstile.verify("stale-token")
    end

    test "refuses a token solved on another hostname" do
      TurnstileStub.with_siteverify(fn _params ->
        {:ok, 200, TurnstileStub.success_body(%{"hostname" => "evil.example"})}
      end)

      assert {:error, :turnstile_failed} = Turnstile.verify("foreign-token")
    end

    test "refuses a response with no hostname at all" do
      TurnstileStub.with_siteverify(fn _params ->
        body = %{"success" => true, "action" => Turnstile.expected_action()} |> Jason.encode!()
        {:ok, 200, body}
      end)

      assert {:error, :turnstile_failed} = Turnstile.verify("token")
    end

    test "accepts every configured hostname" do
      for hostname <- ["fortyfives.net", "www.fortyfives.net", "localhost"] do
        TurnstileStub.with_siteverify(fn _params ->
          {:ok, 200, TurnstileStub.success_body(%{"hostname" => hostname})}
        end)

        assert :ok = Turnstile.verify("token"), "#{hostname} should be accepted"
      end
    end

    test "the hostname allowlist is configurable" do
      previous = Application.fetch_env(:website_45s_v3, :turnstile_hostnames)
      Application.put_env(:website_45s_v3, :turnstile_hostnames, ["staging.example"])

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:website_45s_v3, :turnstile_hostnames, value)
          :error -> Application.delete_env(:website_45s_v3, :turnstile_hostnames)
        end
      end)

      TurnstileStub.with_siteverify(fn _params ->
        {:ok, 200, TurnstileStub.success_body(%{"hostname" => "staging.example"})}
      end)

      assert :ok = Turnstile.verify("token")

      TurnstileStub.with_siteverify(fn _params ->
        {:ok, 200, TurnstileStub.success_body(%{"hostname" => "fortyfives.net"})}
      end)

      assert {:error, :turnstile_failed} = Turnstile.verify("token")
    end

    test "refuses a token issued for a different widget action" do
      TurnstileStub.with_siteverify(fn _params ->
        {:ok, 200, TurnstileStub.success_body(%{"action" => "other-form"})}
      end)

      assert {:error, :turnstile_failed} = Turnstile.verify("token")

      TurnstileStub.with_siteverify(fn _params ->
        body = %{"success" => true, "hostname" => "fortyfives.net"} |> Jason.encode!()
        {:ok, 200, body}
      end)

      assert {:error, :turnstile_failed} = Turnstile.verify("token")
    end

    test "skips the hostname and action checks for Cloudflare's testing keys" do
      # This is the exact shape the documented dummy secret answers with.
      TurnstileStub.with_siteverify(fn _params ->
        body =
          Jason.encode!(%{
            "success" => true,
            "hostname" => "example.com",
            "error-codes" => [],
            "metadata" => %{"result_with_testing_key" => true}
          })

        {:ok, 200, body}
      end)

      assert :ok = Turnstile.verify("token")
    end

    test "refuses a non-200 response" do
      TurnstileStub.with_siteverify(fn _params -> {:ok, 500, "boom"} end)
      assert {:error, :turnstile_failed} = Turnstile.verify("token")
    end

    test "refuses when the request times out or errors" do
      TurnstileStub.with_siteverify(fn _params ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert {:error, :turnstile_failed} = Turnstile.verify("token")
    end

    test "refuses an unparseable body" do
      TurnstileStub.with_siteverify(fn _params -> {:ok, 200, "<html>"} end)
      assert {:error, :turnstile_failed} = Turnstile.verify("token")
    end
  end

  test "does not trust forwarded IP headers from a public direct peer" do
    %Plug.Conn{} = conn = Plug.Test.conn(:get, "/")

    conn = %Plug.Conn{
      conn
      | remote_ip: {203, 0, 113, 10},
        req_headers: [{"cf-connecting-ip", "198.51.100.5"}]
    }

    assert Turnstile.client_ip(conn) == "203.0.113.10"
  end

  describe "IPv4-mapped peers" do
    # Production binds `::`, so a dual-stack listener reports every IPv4 peer —
    # the reverse proxy included — as ::ffff:a.b.c.d. If those are not unmapped,
    # the proxy is not recognised as trusted, forwarded headers are dropped, and
    # every visitor in the world shares one rate-limit key.
    test "a mapped private peer is trusted and its forwarded header honoured" do
      %Plug.Conn{} = conn = Plug.Test.conn(:get, "/")

      conn = %Plug.Conn{
        conn
        | remote_ip: {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 0x0005},
          req_headers: [{"cf-connecting-ip", "198.51.100.5"}]
      }

      assert Turnstile.client_ip(conn) == "198.51.100.5"
    end

    test "a mapped public peer is still not trusted, and reports as IPv4" do
      %Plug.Conn{} = conn = Plug.Test.conn(:get, "/")

      conn = %Plug.Conn{
        conn
        | remote_ip: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x710A},
          req_headers: [{"cf-connecting-ip", "198.51.100.5"}]
      }

      assert Turnstile.client_ip(conn) == "203.0.113.10"
    end

    test "distinct mapped peers do not collapse onto one key" do
      ips =
        for last <- [5, 6, 7] do
          %Plug.Conn{} = conn = Plug.Test.conn(:get, "/")
          conn = %Plug.Conn{conn | remote_ip: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7100 + last}}
          Turnstile.client_ip(conn)
        end

      assert ips == ["203.0.113.5", "203.0.113.6", "203.0.113.7"]
    end

    test "unmap/1 leaves real IPv6 and IPv4 addresses alone" do
      assert Turnstile.unmap({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

      assert Turnstile.unmap({203, 0, 113, 10}) == {203, 0, 113, 10}
      assert Turnstile.unmap(nil) == nil
    end

    test "the LiveView connect_info path unmaps too" do
      assert Turnstile.client_ip(
               [{"x-forwarded-for", "198.51.100.5"}],
               %{address: {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 0x0005}}
             ) == "198.51.100.5"
    end
  end

  test "an unknown peer yields nil rather than a bogus key" do
    assert Turnstile.client_ip(nil, nil) == nil
    assert Turnstile.client_ip([], %{address: nil}) == nil
  end
end
