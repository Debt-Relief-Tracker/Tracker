defmodule DebtReliefTracker.E2EEBrowser do
  @moduledoc """
  Helpers for real-browser tests of the E2EE client flows (use next to
  `DebtReliefTracker.BrowserCase`). The app is loaded through `localhost`, not
  `127.0.0.1`: WebAuthn needs a real rpId, and IndexedDB / BroadcastChannel are
  per origin, so every tab of one test uses the same origin.
  """

  import DebtReliefTracker.BrowserCase
  import DebtReliefTracker.BrowserExtras, only: [js: 2]

  alias DebtReliefTracker.BrowserCase.Driver
  alias DebtReliefTrackerWeb.Holo.DashboardPage

  @doc "Turns E2EE on for this test and restores config afterwards."
  def e2ee_on(opts \\ []) do
    DebtReliefTracker.E2EEHelpers.enable_e2ee()
    put_env(:e2ee_test_hook, Keyword.get(opts, :hook, true))
    put_env(:e2ee_idle_ms, Keyword.get(opts, :idle_ms, 900_000))
    :ok
  end

  defp put_env(key, value) do
    old = Application.fetch_env(:debt_relief_tracker, key)
    Application.put_env(:debt_relief_tracker, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case old do
        {:ok, v} -> Application.put_env(:debt_relief_tracker, key, v)
        :error -> Application.delete_env(:debt_relief_tracker, key)
      end
    end)
  end

  def localhost(%{base_url: base}), do: String.replace(base, "127.0.0.1", "localhost")

  @doc "Opens /app through localhost and waits for the Hologram page to mount."
  def open_app(%{driver: d} = ctx) do
    Driver.call(d, "visit", %{url: localhost(ctx) <> "/app"})
    Driver.call(d, "wait_mounted", %{page: inspect(DashboardPage)})
    ctx
  end

  @doc "Opens a second tab (same browser context) on /app; returns a ctx addressing it."
  def new_tab(%{driver: d} = ctx, name) do
    Driver.call(d, "new_tab", %{name: name})
    tab = %{ctx | driver: {base_port(d), name}}
    open_app(tab)
  end

  def tab(%{driver: d} = ctx, name), do: %{ctx | driver: {base_port(d), name}}

  defp base_port({port, _tab}), do: port
  defp base_port(port), do: port

  @doc "Reloads the current tab and waits for the page."
  def reload(%{driver: d} = ctx) do
    Driver.call(d, "reload", %{})
    Driver.call(d, "wait_mounted", %{page: inspect(DashboardPage)})
    ctx
  end

  @doc """
  Walks the setup wizard with a passphrase and returns `{ctx, recovery_key}`;
  ends on the unlocked home screen.
  """
  def create_vault(ctx, passphrase, opts \\ []) do
    ctx =
      ctx
      |> assert_selector("#vault-setup")
      |> click("#setup-method-passphrase")
      |> fill("#setup-passphrase", passphrase)
      |> fill("#setup-confirm", passphrase)

    ctx = if opts[:remember], do: check(ctx, "#setup-remember"), else: ctx

    ctx
    |> click("#setup-continue")
    |> assert_selector("#setup-recovery-key")

    key = recovery_key_on_screen(ctx, "#setup-recovery-key")
    final = key |> String.split("-") |> List.last()

    ctx
    |> check("#setup-ack-saved")
    |> fill("#setup-ack-final", final)
    |> click("#setup-finish")
    |> assert_selector("#vault-home")

    {ctx, key}
  end

  def recovery_key_on_screen(ctx, selector) do
    js(
      ctx,
      "Array.from(document.querySelectorAll(#{JSON.encode!(selector)} + ' .recovery-group')).map(e => e.textContent.trim()).join('-')"
    )
  end

  def unlock_with_passphrase(ctx, passphrase) do
    ctx
    |> assert_selector("#unlock-passphrase-form")
    |> fill("#unlock-passphrase-input", passphrase)
    |> click("#unlock-passphrase-submit")
  end

  def lock(ctx) do
    ctx |> click("#vault-lock-btn") |> assert_selector("#vault-unlock")
  end

  @doc "Adds a debt through the test hook and waits until it is listed."
  def add_debt(ctx, name) do
    ctx
    |> fill("#test-hook-name", name)
    |> click("#test-hook-add")
    |> assert_text("#vault-debts", name)
  end

  def status(ctx), do: attr(ctx, "#vault-sync-status", "data-status")

  def wait_status(ctx, status) do
    wait_for_expr(
      ctx,
      "document.querySelector('#vault-sync-status')?.dataset.status === #{JSON.encode!(status)}"
    )
  end

  def storage_dump(%{driver: d}), do: Driver.call(d, "storage_dump", %{})
end
