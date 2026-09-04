defmodule Website45sV3.TurnstileTest do
  use ExUnit.Case, async: false

  alias Website45sV3.Turnstile

  test "fails closed when a site key is configured without a secret" do
    previous_site_key = Application.get_env(:website_45s_v3, :turnstile_site_key)
    previous_secret = Application.get_env(:website_45s_v3, :turnstile_secret)

    Application.put_env(:website_45s_v3, :turnstile_site_key, "configured")
    Application.delete_env(:website_45s_v3, :turnstile_secret)

    on_exit(fn ->
      Application.put_env(:website_45s_v3, :turnstile_site_key, previous_site_key)

      if previous_secret do
        Application.put_env(:website_45s_v3, :turnstile_secret, previous_secret)
      else
        Application.delete_env(:website_45s_v3, :turnstile_secret)
      end
    end)

    assert {:error, :turnstile_failed} = Turnstile.verify("token")
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
end
