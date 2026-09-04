defmodule Website45sV3.Security.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Website45sV3.Security.RateLimiter

  setup do
    previous = Application.get_env(:website_45s_v3, :security_rate_limits)

    on_exit(fn ->
      Application.put_env(:website_45s_v3, :security_rate_limits, previous)
      RateLimiter.reset()
    end)

    RateLimiter.reset()
    :ok
  end

  defp put_limits(limits) do
    Application.put_env(:website_45s_v3, :security_rate_limits, limits)
  end

  describe "configuration" do
    test "a partial override keeps the sibling defaults instead of nilling them" do
      # Previously the configured keyword list replaced the defaults wholesale,
      # so this left window_ms nil — which refused every login outright, or
      # crashed the limiter on `now - nil`.
      put_limits(login: [max_ip: 2])

      assert :ok = RateLimiter.check_login_ip("203.0.113.9")
      assert :ok = RateLimiter.check_login_ip("203.0.113.9")
      assert {:error, :rate_limited} = RateLimiter.check_login_ip("203.0.113.9")

      # max_account was not configured, so its default budget is intact.
      refute RateLimiter.login_account_exhausted?({:user, 1})
    end
  end

  describe "IPv6 rotation" do
    test "login attempts from one /64 share a budget" do
      put_limits(login: [window_ms: 60_000, max_ip: 2, max_account: 100])

      assert :ok = RateLimiter.check_login_ip("2001:db8:1:1::1")
      assert :ok = RateLimiter.check_login_ip("2001:db8:1:1::2")
      assert {:error, :rate_limited} = RateLimiter.check_login_ip("2001:db8:1:1::3")

      # A different /64 is a different client.
      assert :ok = RateLimiter.check_login_ip("2001:db8:1:2::1")
    end

    test "queue joins from one /64 share a budget" do
      put_limits(queue: [window_ms: 60_000, max_ip: 1, max_create_ip: 100])

      assert :ok = RateLimiter.check_queue_join("2001:db8:1:1::1")
      assert {:error, :rate_limited} = RateLimiter.check_queue_join("2001:db8:1:1::9999")
    end

    test "IPv4-mapped addresses are treated as the IPv4 clients they are" do
      put_limits(queue: [window_ms: 60_000, max_ip: 1, max_create_ip: 100])

      # If these collapsed to a /64 they would all be one key, since every
      # mapped address begins 0:0:0:0.
      assert :ok = RateLimiter.check_queue_join("::ffff:203.0.113.1")
      assert :ok = RateLimiter.check_queue_join("::ffff:203.0.113.2")
      assert {:error, :rate_limited} = RateLimiter.check_queue_join("::ffff:203.0.113.1")
    end
  end

  describe "login accounts" do
    test "exhaustion is reported without consuming budget" do
      put_limits(login: [window_ms: 60_000, max_ip: 100, max_account: 2])

      refute RateLimiter.login_account_exhausted?({:user, 7})
      refute RateLimiter.login_account_exhausted?({:user, 7})
      refute RateLimiter.login_account_exhausted?({:user, 7})

      RateLimiter.record_login_failure({:user, 7})
      refute RateLimiter.login_account_exhausted?({:user, 7})

      RateLimiter.record_login_failure({:user, 7})
      assert RateLimiter.login_account_exhausted?({:user, 7})
    end

    test "an absent account key is not reported as exhausted" do
      # A malformed login has no account to charge; answering true here used to
      # surface as a bogus "too many attempts" message.
      refute RateLimiter.login_account_exhausted?(nil)
    end

    test "a successful login clears the account's failures" do
      put_limits(login: [window_ms: 60_000, max_ip: 100, max_account: 1])

      RateLimiter.record_login_failure({:user, 7})
      assert RateLimiter.login_account_exhausted?({:user, 7})

      RateLimiter.reset_login_account({:user, 7})
      refute RateLimiter.login_account_exhausted?({:user, 7})
    end

    test "identifiers are matched case- and whitespace-insensitively" do
      put_limits(login: [window_ms: 60_000, max_ip: 100, max_account: 1])

      RateLimiter.record_login_failure("  Player@Example.COM ")
      assert RateLimiter.login_account_exhausted?("player@example.com")
    end
  end

  describe "outbound mail" do
    test "one address cannot be flooded from many networks" do
      put_limits(email: [window_ms: 60_000, max_ip: 100, max_address: 2])

      assert :ok = RateLimiter.check_email_send("203.0.113.1", "victim@example.com")
      assert :ok = RateLimiter.check_email_send("203.0.113.2", "victim@example.com")

      assert {:error, :rate_limited} =
               RateLimiter.check_email_send("203.0.113.3", "victim@example.com")

      # Another recipient is unaffected.
      assert :ok = RateLimiter.check_email_send("203.0.113.3", "someone@example.com")
    end

    test "one network cannot flood many addresses" do
      put_limits(email: [window_ms: 60_000, max_ip: 2, max_address: 100])

      assert :ok = RateLimiter.check_email_send("203.0.113.1", "a@example.com")
      assert :ok = RateLimiter.check_email_send("203.0.113.1", "b@example.com")

      assert {:error, :rate_limited} =
               RateLimiter.check_email_send("203.0.113.1", "c@example.com")
    end

    test "an unknown client IP still gets the per-address cap" do
      put_limits(email: [window_ms: 60_000, max_ip: 100, max_address: 1])

      assert :ok = RateLimiter.check_email_send(nil, "victim@example.com")

      assert {:error, :rate_limited} =
               RateLimiter.check_email_send(nil, "victim@example.com")
    end

    test "a request with nothing chargeable at all is refused" do
      assert {:error, :rate_limited} = RateLimiter.check_email_send(nil, "   ")
    end
  end

  describe "registration" do
    test "accounts created from one network are capped" do
      put_limits(registration: [window_ms: 60_000, max_ip: 2])

      refute RateLimiter.registration_exhausted?("203.0.113.1")
      RateLimiter.record_registration("203.0.113.1")
      refute RateLimiter.registration_exhausted?("203.0.113.1")
      RateLimiter.record_registration("203.0.113.1")

      assert RateLimiter.registration_exhausted?("203.0.113.1")
      refute RateLimiter.registration_exhausted?("203.0.113.2")
    end

    test "a rejected signup does not consume the network budget" do
      put_limits(registration: [window_ms: 60_000, max_ip: 1])

      # Only successful registrations are recorded, so someone fumbling the
      # form cannot lock themselves out of signing up.
      refute RateLimiter.registration_exhausted?("203.0.113.1")
      refute RateLimiter.registration_exhausted?("203.0.113.1")
      refute RateLimiter.registration_exhausted?("203.0.113.1")

      RateLimiter.record_registration("203.0.113.1")
      assert RateLimiter.registration_exhausted?("203.0.113.1")
    end
  end
end
