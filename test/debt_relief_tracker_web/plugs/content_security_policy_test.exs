defmodule DebtReliefTrackerWeb.Plugs.ContentSecurityPolicyTest do
  use DebtReliefTrackerWeb.ConnCase, async: false

  alias DebtReliefTrackerWeb.Plugs.ContentSecurityPolicy, as: CSP

  @inline_a ~s|<script>\n  globalThis.Hologram ??= {};\n  globalThis.Hologram.csrfToken = "x";\n</script>|
  @inline_b ~s|<script>\n  globalThis.Hologram.pageMountData = (deps) => ({a: "<script>"});\n</script>|
  @external ~s|<script async src="/hologram/runtime.js"></script>|
  @page "<!DOCTYPE html><html><head>#{@inline_a}#{@external}\n#{@inline_b}<script src=\"/assets/js/holo_account.js\"></script></head><body><p>hi</p></body></html>"

  # A stand-in for Hologram: serves a fixed page (iodata body) at /app or
  # /hologram/command, so the plug is exercised in isolation.
  defp run(path, body, content_type \\ "text/html", method \\ :get) do
    method
    |> Plug.Test.conn(path)
    |> CSP.call([])
    |> put_resp_content_type(content_type)
    |> send_resp(200, body)
  end

  defp nonce_of(conn) do
    [csp] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([A-Za-z0-9_-]+)'/, csp)
    nonce
  end

  test "header content: strict policy, no unsafe-inline for scripts" do
    conn = run("/app", @page)
    [csp] = get_resp_header(conn, "content-security-policy")
    directives = String.split(csp, "; ")

    assert "default-src 'none'" in directives
    # 'unsafe-eval': required by Hologram's runtime (new Function); see the plug.
    assert "script-src 'self' 'nonce-#{nonce_of(conn)}' 'unsafe-eval' 'wasm-unsafe-eval'" in directives
    assert "style-src-attr 'unsafe-inline'" in directives
    assert "style-src 'self'" in directives
    assert "connect-src 'self'" in directives
    assert "object-src 'none'" in directives
    assert "base-uri 'none'" in directives
    assert "frame-ancestors 'none'" in directives
    assert "form-action 'self'" in directives
    refute Enum.find(directives, &String.starts_with?(&1, "script-src")) =~ "unsafe-inline"

    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "nonce is fresh per request (200 requests, all distinct, >= 128 bits)" do
    nonces = for _ <- 1..200, do: nonce_of(run("/app", @page))
    assert length(Enum.uniq(nonces)) == 200
    assert Enum.all?(nonces, &(byte_size(Base.url_decode64!(&1, padding: false)) >= 16))
  end

  test "every recognised inline script gets the nonce, external ones and the rest are untouched" do
    conn = run("/app", [@page])
    nonce = nonce_of(conn)
    body = conn.resp_body

    assert body ==
             @page
             |> String.replace(
               "<script>\n  globalThis",
               "<script nonce=\"#{nonce}\">\n  globalThis"
             )

    assert length(Regex.scan(~r/<script nonce="#{nonce}">/, body)) == 2
    assert body =~ @external
    assert body =~ ~s|<script src="/assets/js/holo_account.js"></script>|
    # content of a script (including a "<script>" inside a string) is untouched
    assert body =~ ~s|({a: "<script>"})|
  end

  test "iodata bodies are handled" do
    conn =
      run("/app", [["<!DOCTYPE html>", "<script>\n globalThis.Hologram ??= {};"], "</script>"])

    assert conn.resp_body =~ ~s|<script nonce="#{nonce_of(conn)}">|
  end

  test "unknown inline scripts are never given the nonce" do
    conn = run("/app", "<html><script>alert(1)</script>#{@inline_a}</html>")
    assert conn.resp_body =~ "<script>alert(1)</script>"
    assert length(Regex.scan(~r/nonce=/, conn.resp_body)) == 1
  end

  test "an attacker-supplied nonce attribute is not trusted or duplicated" do
    conn = run("/app", ~s|<script nonce="evil">globalThis.Hologram ??= {};</script>|)
    refute conn.resp_body =~ nonce_of(conn)
  end

  test "non-HTML responses are untouched apart from headers" do
    body = ~s|{"x":"<script>globalThis.Hologram ??= {};</script>"}|
    conn = run("/hologram/command", body, "application/json")
    assert conn.resp_body == body
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "HEAD requests work" do
    conn = run("/app", @page, "text/html", :head)
    assert conn.status == 200
    assert get_resp_header(conn, "content-security-policy") != []
  end

  test "other paths are not touched" do
    conn = run("/", @page)
    assert get_resp_header(conn, "content-security-policy") == []
    assert conn.resp_body == @page
  end

  describe "form-action and the OIDC logout redirect" do
    setup do
      on_exit(fn -> Application.put_env(:debt_relief_tracker, :oidc, nil) end)
    end

    test "is 'self' only without OIDC" do
      [csp] = get_resp_header(run("/app", @page), "content-security-policy")
      assert csp =~ "form-action 'self'"
      refute csp =~ "form-action 'self' "
    end

    test "adds the issuer origin (and only the origin) when OIDC is configured" do
      Application.put_env(:debt_relief_tracker, :oidc,
        issuer: "https://tenant.eu.auth0.com/",
        client_id: "c",
        client_secret: "s"
      )

      [csp] = get_resp_header(run("/app", @page), "content-security-policy")
      assert csp =~ "form-action 'self' https://tenant.eu.auth0.com"
      refute csp =~ "auth0.com/"
    end
  end

  describe "modes" do
    setup do
      old = Application.get_env(:debt_relief_tracker, :csp)

      on_exit(fn ->
        if old,
          do: Application.put_env(:debt_relief_tracker, :csp, old),
          else: Application.delete_env(:debt_relief_tracker, :csp)
      end)
    end

    test "report_only uses the report-only header" do
      Application.put_env(:debt_relief_tracker, :csp, mode: :report_only)
      conn = run("/app", @page)
      assert get_resp_header(conn, "content-security-policy") == []
      assert [_] = get_resp_header(conn, "content-security-policy-report-only")
      assert conn.resp_body =~ "nonce="
    end

    test "off does nothing" do
      Application.put_env(:debt_relief_tracker, :csp, mode: :off)
      conn = run("/app", @page)
      assert get_resp_header(conn, "content-security-policy") == []
      assert conn.resp_body == @page
    end
  end

  describe "through the real endpoint (Hologram's actual first-load page)" do
    test "/app carries a nonce on exactly the two inline scripts, after placeholders were replaced" do
      conn = Phoenix.ConnTest.get(Phoenix.ConnTest.build_conn(), "/app")
      assert conn.status == 200
      nonce = nonce_of(conn)
      body = conn.resp_body

      refute body =~ "PLACEHOLDER"
      assert length(Regex.scan(~r/<script nonce="#{nonce}">/, body)) == 2
      # every inline script (no src) has the nonce
      assert [] == Regex.scan(~r/<script>/, body)
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      other = nonce_of(Phoenix.ConnTest.get(Phoenix.ConnTest.build_conn(), "/app"))
      assert other != nonce
    end

    test "the LiveView / is left alone" do
      conn = Phoenix.ConnTest.get(Phoenix.ConnTest.build_conn(), "/")
      refute get_resp_header(conn, "content-security-policy") |> Enum.join() =~ "nonce-"
      refute conn.resp_body =~ "script nonce"
      assert get_resp_header(conn, "cache-control") != ["no-store"]
    end
  end

  test "no JS.eval / JS.exec / ~JS in lib/ (they need 'unsafe-eval' via Hologram's new Function)" do
    offenders =
      "lib/**/*.{ex,exs,heex}"
      |> Path.wildcard()
      |> Enum.filter(fn f ->
        File.read!(f) =~ ~r/\bJS\.(eval|exec)\b|~JS\b|\bJS\.(eval|exec)\(/
      end)

    assert offenders == []
  end
end
