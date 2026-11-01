defmodule DebtReliefTrackerWeb.Holo.E2EEDashboardBrowserTest do
  @moduledoc """
  The full dashboard in E2EE mode (roadmap Phase 10 data path): the same
  flows as the plaintext browser tests, asserted through the UI because the
  server holds only ciphertext.
  """
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.E2EEBrowser
  import DebtReliefTracker.BrowserExtras, only: [errors: 1]

  alias DebtReliefTracker.Accounts

  @pass "correct horse battery staple 77"

  setup do
    {:ok, _} = Accounts.set_tutorial_seen(Accounts.get_default_user!(), true)
    e2ee_on(hook: false)
    :ok
  end

  defp unlocked(ctx) do
    ctx = open_app(ctx)
    {ctx, _key} = create_vault(ctx, @pass)
    ctx
  end

  test "smoke: the full dashboard renders after creating a vault", ctx do
    ctx = unlocked(ctx)

    ctx
    |> assert_selector("#app-header")
    |> assert_selector("#debt-sidebar")
    |> assert_selector("#plan-panel")
    |> assert_selector("#add-debt-button")

    assert errors(ctx) == []
  end
end
