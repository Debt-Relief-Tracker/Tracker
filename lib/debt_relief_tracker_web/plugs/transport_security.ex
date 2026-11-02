defmodule DebtReliefTrackerWeb.Plugs.TransportSecurity do
  @moduledoc """
  Opt-in production TLS hardening, toggled at RUNTIME (`FORCE_SSL` env, read
  in `config/runtime.exs` into `:debt_relief_tracker, :force_ssl`), because
  Phoenix's `force_ssl` and `Plug.Session` options are compile-time. Default
  OFF so plain-HTTP self-hosting (Docker on localhost) keeps working.

  When ON: plain-HTTP requests are redirected to HTTPS (`x-forwarded-proto`
  is honoured, Render terminates TLS), HTTPS responses carry
  `strict-transport-security`, and every cookie set on the response
  (including the session cookie) is marked `Secure`.

  Must be plugged before `Plug.Session` (its `before_send` then runs after
  the session cookie is written).
  """

  @behaviour Plug

  import Plug.Conn

  @ssl_opts [rewrite_on: [:x_forwarded_proto], hsts: true]

  @impl true
  def init(_opts), do: Plug.SSL.init(@ssl_opts)

  @impl true
  def call(conn, ssl) do
    if Application.get_env(:debt_relief_tracker, :force_ssl, false) == true do
      conn = Plug.SSL.call(conn, ssl)
      if conn.halted, do: conn, else: register_before_send(conn, &secure_cookies/1)
    else
      conn
    end
  end

  defp secure_cookies(conn) do
    cookies =
      Map.new(conn.resp_cookies, fn {name, opts} -> {name, Map.put(opts, :secure, true)} end)

    %{conn | resp_cookies: cookies}
  end
end
