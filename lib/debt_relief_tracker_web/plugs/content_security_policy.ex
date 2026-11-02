defmodule DebtReliefTrackerWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Strict Content-Security-Policy for the Hologram app (`/app` and Hologram's
  own `/hologram/*` command endpoints). See docs/architecture/0007-e2ee.md,
  "Content-Security-Policy".

  Hologram's first-load HTML carries two inline `<script>` blocks with
  per-request values (CSRF token, instance id, page params), so hashes cannot
  work and the component has no nonce support. This plug therefore:

    1. generates a fresh 128-bit nonce per request (base64url),
    2. sets the policy header (`script-src 'self' 'nonce-<n>' 'unsafe-eval'
       'wasm-unsafe-eval'`, no `'unsafe-inline'`). `'unsafe-eval'` is NOT
       optional: Hologram 0.12's client runtime rebuilds every server payload
       (SSE handshake, command replies, page mount data) with `new Function`
       (`Interpreter.evaluateJavaScriptCode`), verified in a real browser.
       `'wasm-unsafe-eval'` is for the Argon2 facade and stays listed so it
       survives a Hologram that drops `new Function`,
    3. in a `register_before_send` callback -- which runs after Hologram has
       substituted its placeholders -- adds `nonce="<n>"` to the inline
       scripts it can account for (see `@known_inline_scripts`), and
    4. marks the HTML and command responses `Cache-Control: no-store`, so a
       nonce is never replayed from a cache.

  Inline scripts it does NOT recognise are left without a nonce on purpose
  (the browser blocks them; a warning is logged), so a script injected into
  the page can never inherit the nonce.

  The LiveView pages (`/admin`, `/auth/*`; `/` only redirects to `/app`) get a sibling, nonce-less
  policy (`liveview_policy/0`): they have no inline scripts (the theme boot
  lives in `assets/js/theme_boot.js`), so `script-src 'self'` suffices. They
  share an origin -- and so IndexedDB with the remembered vault key -- with
  `/app`, hence an XSS there must not be possible. Dev-only routes (`/dev/*`,
  LiveDashboard), `/api/*` (Swagger UI) and CSV exports are not touched.

  Mode: `config :debt_relief_tracker, :csp, mode: :enforce | :report_only | :off`
  (read per request; default `:enforce`).
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  # The only inline scripts Hologram.UI.Runtime emits, identified by the start
  # of their body (whitespace-trimmed). Re-verify on each Hologram upgrade.
  @known_inline_scripts [
    "globalThis.Hologram ??= {};",
    "globalThis.Hologram.pageMountData = "
  ]

  @doc "True for the Hologram request paths (nonce policy)."
  def applies_to?(path), do: path == "/app" or String.starts_with?(path, ["/app/", "/hologram/"])

  @doc "True for the LiveView / browser-pipeline HTML paths (static policy)."
  def liveview_applies?(path), do: path in ["/admin"] or String.starts_with?(path, "/auth/")

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    path = conn.request_path

    cond do
      mode() == :off -> conn
      applies_to?(path) -> apply_policy(conn, mode())
      liveview_applies?(path) -> apply_liveview_policy(conn, mode())
      true -> conn
    end
  end

  defp header_name(:report_only), do: "content-security-policy-report-only"
  defp header_name(_), do: "content-security-policy"

  defp apply_liveview_policy(conn, mode) do
    conn
    |> put_resp_header(header_name(mode), liveview_policy())
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  @doc """
  The policy for the LiveView pages. No nonce, no `'unsafe-inline'` for
  scripts. `connect-src 'self'` covers the same-origin LiveView WebSocket
  (CSP3: `'self'` matches ws/wss on the same host; verified in the browser
  test), so no `ws:`/`wss:` wildcard is listed. When Umami analytics is
  configured its origin is added to `script-src` and `connect-src`.
  """
  def liveview_policy do
    umami = umami_origin()

    Enum.join(
      [
        "default-src 'none'",
        "script-src 'self'" <> umami,
        "style-src 'self'",
        "connect-src 'self'" <> umami,
        "img-src 'self' data:",
        "font-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
        "form-action #{form_action_sources()}"
      ],
      "; "
    )
  end

  defp umami_origin do
    with false <- DebtReliefTracker.E2EE.enabled?(),
         cfg when is_list(cfg) <- Application.get_env(:debt_relief_tracker, :umami),
         url when is_binary(url) <- cfg[:script_url],
         %URI{scheme: scheme, host: host, port: port} when is_binary(host) <- URI.parse(url) do
      if port in [nil, URI.default_port(scheme)],
        do: " #{scheme}://#{host}",
        else: " #{scheme}://#{host}:#{port}"
    else
      _ -> ""
    end
  end

  @doc "The configured mode (`:enforce`, `:report_only` or `:off`)."
  def mode do
    :debt_relief_tracker |> Application.get_env(:csp, []) |> Keyword.get(:mode, :enforce)
  end

  @doc "The policy string for `nonce`. Adds the Umami origin only when configured and E2EE is off."
  def policy(nonce) do
    umami = umami_origin()

    Enum.join(
      [
        "default-src 'none'",
        "script-src 'self' 'nonce-#{nonce}' 'unsafe-eval' 'wasm-unsafe-eval'" <> umami,
        "style-src 'self'",
        "style-src-attr 'unsafe-inline'",
        "connect-src 'self'" <> umami,
        "img-src 'self' data:",
        "font-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
        "form-action #{form_action_sources()}"
      ],
      "; "
    )
  end

  # The logout POST (same origin) is answered with a redirect to the IdP's
  # logout endpoint (AuthController.logout), and browsers (Chrome) apply
  # form-action to redirects after a form submission, so the configured OIDC
  # issuer's origin must be allowed. Nothing else leaves the origin.
  defp form_action_sources do
    with true <- DebtReliefTrackerWeb.OIDC.enabled?(),
         issuer when is_binary(issuer) <-
           :debt_relief_tracker |> Application.get_env(:oidc) |> Keyword.get(:issuer),
         %URI{scheme: scheme, host: host, port: port} when is_binary(host) <- URI.parse(issuer) do
      default? = port in [nil, URI.default_port(scheme)]
      origin = if default?, do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
      "'self' #{origin}"
    else
      _ -> "'self'"
    end
  end

  defp apply_policy(conn, mode) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    conn
    |> put_resp_header(header_name(mode), policy(nonce))
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> register_before_send(&finish(&1, nonce))
  end

  defp finish(conn, nonce) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if html?(conn) and conn.resp_body != nil and conn.status != 204 do
      body = conn.resp_body |> IO.iodata_to_binary() |> add_nonces(nonce)
      %{conn | resp_body: body}
    else
      conn
    end
  end

  defp html?(conn) do
    case get_resp_header(conn, "content-type") do
      [type | _] -> String.starts_with?(type, "text/html")
      [] -> false
    end
  end

  @doc """
  Adds `nonce` to the recognised inline `<script>` blocks of `html` and
  returns the new body. Everything else is byte-for-byte unchanged. Scans
  tag by tag and skips each script's body, so a `<script` inside a script
  string is never mistaken for a tag.
  """
  def add_nonces(html, nonce) when is_binary(html) do
    html |> scan(nonce, []) |> IO.iodata_to_binary()
  end

  defp scan(html, nonce, acc) do
    case Regex.run(~r/<script(?=[\s>\/])/i, html, return: :index) do
      nil ->
        Enum.reverse([html | acc])

      [{start, len}] ->
        {before, rest} = split(html, start)
        after_name = binary_part(rest, len, byte_size(rest) - len)

        case :binary.match(after_name, ">") do
          :nomatch ->
            Enum.reverse([rest, before | acc])

          {gt, 1} ->
            attrs = binary_part(after_name, 0, gt)
            tail = binary_part(after_name, gt + 1, byte_size(after_name) - gt - 1)
            {content, remainder} = take_body(tail)

            open =
              if inline?(attrs) and known?(content) do
                ["<script nonce=\"", nonce, "\"", attrs, ">"]
              else
                if inline?(attrs) do
                  Logger.warning(
                    "CSP: inline <script> not in the known Hologram list; left without nonce"
                  )
                end

                ["<script", attrs, ">"]
              end

            scan(remainder, nonce, [content, open, before | acc])
        end
    end
  end

  # Content up to (not including) the closing tag, and the rest from it.
  defp take_body(tail) do
    case Regex.run(~r/<\/script/i, tail, return: :index) do
      nil -> {tail, ""}
      [{pos, _}] -> split(tail, pos)
    end
  end

  defp split(bin, pos),
    do: {binary_part(bin, 0, pos), binary_part(bin, pos, byte_size(bin) - pos)}

  # No src= attribute (matches `src`, not `data-src`) and no existing nonce.
  defp inline?(attrs), do: not Regex.match?(~r/(^|[\s"'])(src|nonce)\s*=/i, attrs)

  defp known?(content) do
    trimmed = String.trim_leading(content)
    Enum.any?(@known_inline_scripts, &String.starts_with?(trimmed, &1))
  end
end
