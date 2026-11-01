defmodule DebtReliefTrackerWeb.Plugs.TransportSecurityTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias DebtReliefTrackerWeb.Plugs.TransportSecurity

  @session Plug.Session.init(store: :cookie, key: "_k", signing_salt: "salt1234")

  setup do
    prev = Application.get_env(:debt_relief_tracker, :force_ssl)
    on_exit(fn -> Application.put_env(:debt_relief_tracker, :force_ssl, prev) end)
  end

  defp run(headers \\ []) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:get, "/"), fn {k, v}, c -> put_req_header(c, k, v) end)

    conn = %{conn | secret_key_base: String.duplicate("a", 64)}
    conn = TransportSecurity.call(conn, TransportSecurity.init([]))

    if conn.halted do
      conn
    else
      conn
      |> Plug.Session.call(@session)
      |> fetch_session()
      |> put_session(:x, 1)
      |> send_resp(200, "ok")
    end
  end

  defp set_cookie(conn), do: conn |> get_resp_header("set-cookie") |> Enum.join("\n")

  test "flag off: unchanged (no redirect, no HSTS, cookie not Secure)" do
    Application.put_env(:debt_relief_tracker, :force_ssl, false)
    conn = run()
    assert conn.status == 200
    assert get_resp_header(conn, "strict-transport-security") == []
    refute String.contains?(String.downcase(set_cookie(conn)), "secure")
  end

  test "flag on: x-forwarded-proto http is redirected to https" do
    Application.put_env(:debt_relief_tracker, :force_ssl, true)
    conn = run([{"x-forwarded-proto", "http"}])
    assert conn.status in [301, 308]
    assert [location] = get_resp_header(conn, "location")
    assert String.starts_with?(location, "https://")
  end

  test "flag on: x-forwarded-proto https passes, HSTS sent, cookie is Secure" do
    Application.put_env(:debt_relief_tracker, :force_ssl, true)
    conn = run([{"x-forwarded-proto", "https"}])
    assert conn.status == 200
    assert [_] = get_resp_header(conn, "strict-transport-security")
    assert String.contains?(String.downcase(set_cookie(conn)), "secure")
  end
end
