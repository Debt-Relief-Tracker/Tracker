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
    {:ok, driver: Driver.start!()}
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

  def text(%{driver: d}, selector), do: Driver.call(d, "text", %{selector: selector})

  def current_path(%{driver: d}), do: Driver.call(d, "path", %{})

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
