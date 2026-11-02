defmodule DebtReliefTracker.BrowserCase do
  @moduledoc """
  ExUnit case template for real-browser tests of the Hologram UI.

  Tests using it are tagged `:browser`, which `test/test_helper.exs` excludes
  by default; run them with `mix test --include browser`.

  What it does:

    * serves `DebtReliefTrackerWeb.Endpoint` over real HTTP on a free
      loopback port, from inside the test run (a second Bandit listener in
      front of the already-supervised endpoint; `server: false` stays in
      config, and neither `mix phx.server` nor `mix holo` is involved);
    * checks out the Ecto sandbox in shared mode (this case is never async), so
      the server's request/command processes see the data a test seeded;
    * drives a headless Chromium through `test/browser/driver.mjs`
      (Playwright), one browser per test.

  Any Content-Security-Policy violation seen by the page fails the test
  (opt out per test with `@tag csp: :allow`).

  Helpers (all take and return nothing interesting; they raise on failure):
  `visit_page/2`, `visit/2`, `click/2`, `fill/3`, `text/2`,
  `assert_selector/2`, `refute_selector/2`, `assert_text/3`, `current_path/1`.
  """

  use ExUnit.CaseTemplate

  alias DebtReliefTracker.BrowserCase.Driver

  using do
    quote do
      @moduletag :browser

      import DebtReliefTracker.BrowserCase
    end
  end

  setup_all do
    # Normally a no-op (`mix test` sets HOLOGRAM_START=1 and compiles the
    # runtime bundle); makes `mix test` invoked some other way work too.
    ensure_hologram!()
    ensure_assets!()
    load_app_modules!()

    {:ok, bandit} =
      Bandit.start_link(
        plug: DebtReliefTrackerWeb.Endpoint,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, base_url: "http://127.0.0.1:#{port}"}
  end

  setup tags do
    DebtReliefTracker.DataCase.setup_sandbox(tags)

    # One browser per test, opened by the test process: a Port delivers its
    # replies to its owner, so it can't be opened in setup_all. It is closed
    # automatically when the test process exits.
    #
    # Content-Security-Policy: the endpoint enforces the strict Hologram policy in
    # tests, and the driver logs every `securitypolicyviolation` event to a
    # per-test file. Any violation fails the test (checked in on_exit, so even
    # one after the last driver call counts). Opt out with `@tag csp: :allow`.
    csp_log =
      Path.join(
        System.tmp_dir!(),
        "csp-violations-#{System.unique_integer([:positive])}.jsonl"
      )

    ExUnit.Callbacks.on_exit(fn ->
      violations =
        case File.read(csp_log) do
          {:ok, data} -> String.split(data, "\n", trim: true)
          _ -> []
        end

      File.rm(csp_log)

      if violations != [] and tags[:csp] != :allow do
        raise ExUnit.AssertionError,
          message: "CSP violations in the browser:\n" <> Enum.join(violations, "\n")
      end
    end)

    {:ok, driver: Driver.start!(csp_log)}
  end

  # The Hologram layout loads /assets/js/holo_account.js and /assets/css/app.css,
  # which are build outputs (gitignored). Build them (~1s) so the pages work.
  defp ensure_assets! do
    Mix.Task.run("assets.build")

    # A past `mix assets.deploy` (phx.digest) leaves `.gz` siblings that
    # Plug.Static serves in preference to the fresh files when gzip is on
    # (it is, outside code reloading), so the browser would get a stale
    # stylesheet -- e.g. missing newer `sm:flex` classes, which hides the debt
    # list. They are gitignored build output; drop them so tests see the build.
    for gz <- Path.wildcard(Path.expand("priv/static/assets/**/*.gz")), do: File.rm(gz)
  end

  # Hologram decodes a command's name with `binary_to_existing_atom/1`, so a
  # component module that hasn't been loaded yet (e.g. a modal that the
  # server never rendered) makes its first command fail with "not an already
  # existing atom". Releases load every module at boot; do the same here.
  defp load_app_modules! do
    {:ok, modules} = :application.get_key(:debt_relief_tracker, :modules)
    Enum.each(modules, &Code.ensure_loaded/1)
  end

  defp ensure_hologram! do
    unless Application.started_applications() |> List.keymember?(:hologram, 0) do
      {:ok, _} = Hologram.Test.setup()
    end
  end

  # --- helpers -------------------------------------------------------------

  @doc "Navigates to `path` without waiting for Hologram to mount anything."
  def visit(%{driver: d, base_url: base}, path), do: Driver.call(d, "visit", %{url: base <> path})

  @doc """
  Navigates to the route of `page_module` and blocks until the Hologram
  runtime has mounted that page and its WebSocket and SSE connections are up
  (the same readiness signals as `Hologram.Test.FeatureHelpers.assert_page/4`),
  so a following click can't race the runtime attaching its listeners.
  """
  def visit_page(%{driver: d} = ctx, page_module) do
    visit(ctx, Hologram.Router.Helpers.page_path(page_module))
    Driver.call(d, "wait_mounted", %{page: inspect(page_module)})
    ctx
  end

  def click(%{driver: d} = ctx, selector) do
    Driver.call(d, "click", %{selector: selector})
    ctx
  end

  def fill(%{driver: d} = ctx, selector, value) do
    Driver.call(d, "fill", %{selector: selector, value: value})
    ctx
  end

  @doc "Chooses the `<option>` with `value` in the `<select>` at `selector`."
  def select(%{driver: d} = ctx, selector, value) do
    Driver.call(d, "select", %{selector: selector, value: value})
    ctx
  end

  @doc "Presses a key on the page (e.g. \"Escape\")."
  def press(%{driver: d} = ctx, key) do
    Driver.call(d, "press", %{key: key})
    ctx
  end

  @doc "Clicks `selector` at pixel offset (x, y) from its top-left corner."
  def click_at(%{driver: d} = ctx, selector, x, y) do
    Driver.call(d, "click_at", %{selector: selector, x: x, y: y})
    ctx
  end

  def check(%{driver: d} = ctx, selector) do
    Driver.call(d, "check", %{selector: selector})
    ctx
  end

  @doc "Current value of an input (raises if absent; see BrowserExtras.value/2 for a nil-safe read)."
  def input_value(%{driver: d}, selector), do: Driver.call(d, "value", %{selector: selector})

  @doc "Mouse click at viewport coordinates (e.g. on the overlay outside a dialog)."
  def click_xy(%{driver: d} = ctx, x, y) do
    Driver.call(d, "click_xy", %{x: x, y: y})
    ctx
  end

  def text(%{driver: d}, selector), do: Driver.call(d, "text", %{selector: selector})

  def current_path(%{driver: d}), do: Driver.call(d, "path", %{})

  @doc "Number of elements matching `selector` right now (no waiting)."
  def count(%{driver: d}, selector), do: Driver.call(d, "count", %{selector: selector})

  @doc "Attribute `name` of the first element matching `selector`."
  def attr(%{driver: d}, selector, name),
    do: Driver.call(d, "attr", %{selector: selector, name: name})

  @doc "Evaluates a JS expression in the page and returns its JSON value."
  def eval(%{driver: d}, expr), do: Driver.call(d, "eval", %{expr: expr})

  @doc "Waits until the JS expression is truthy; raises on timeout."
  def wait_for_expr(%{driver: d} = ctx, expr) do
    Driver.call(d, "wait_for_expr", %{expr: expr})
    ctx
  end

  @doc "Waits until the page URL path matches the regex `pattern`."
  def wait_for_url(%{driver: d} = ctx, pattern) do
    Driver.call(d, "wait_for_url", %{pattern: pattern})
    ctx
  end

  @doc "Sets a cookie in the browser for this test's server."
  def add_cookie(%{driver: d, base_url: base} = ctx, name, value) do
    Driver.call(d, "add_cookie", %{name: name, value: value, url: base})
    ctx
  end

  @doc "All cookies in the browser, as maps with `\"name\"`/`\"value\"`."
  def cookies(%{driver: d}), do: Driver.call(d, "cookies", %{})

  @doc """
  Signs the browser in as `user` by planting a real Phoenix session cookie
  (needs OIDC enabled in app env). The cookie is produced by running a
  request through the endpoint with a test session, so it is signed exactly
  like production's.
  """
  def sign_in(ctx, user) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(user_id: user.id)
      |> Phoenix.ConnTest.dispatch(DebtReliefTrackerWeb.Endpoint, :get, "/")

    %{value: value} = conn.resp_cookies["_debt_relief_tracker_key"]
    add_cookie(ctx, "_debt_relief_tracker_key", value)
  end

  @doc "Waits until `selector` is visible; raises on timeout."
  def assert_selector(%{driver: d} = ctx, selector) do
    Driver.call(d, "wait_for_selector", %{selector: selector, state: "visible"})
    ctx
  end

  @doc "Waits until `selector` is absent/hidden; raises on timeout."
  def refute_selector(%{driver: d} = ctx, selector) do
    Driver.call(d, "wait_for_selector", %{selector: selector, state: "hidden"})
    ctx
  end

  @doc "Waits until the element at `selector` contains `text`; raises on timeout."
  def assert_text(%{driver: d} = ctx, selector, text) do
    Driver.call(d, "wait_for_text", %{selector: selector, text: text})
    ctx
  end
end
