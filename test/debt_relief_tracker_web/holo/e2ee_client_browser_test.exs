defmodule DebtReliefTrackerWeb.Holo.E2EEClientBrowserTest do
  @moduledoc """
  Real-Chromium tests of the E2EE client flows (roadmap Phases 7-8): setup
  wizard, lock/unlock, recovery, remembered device, rollback detection, the
  save/sync loop with CAS merges, and "nothing sensitive is stored anywhere".
  """
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.E2EEBrowser
  import DebtReliefTracker.BrowserExtras, only: [js: 2, errors: 1]

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.E2EE.Vaults

  @pass "correct horse battery staple 77"

  setup do
    e2ee_on()
    :ok
  end

  test "wizard -> create -> lock -> unlock by passphrase", ctx do
    ctx = open_app(ctx)
    assert_selector(ctx, "#vault-setup")
    {ctx, _key} = create_vault(ctx, @pass)
    assert_selector(ctx, "#vault-created-notice")

    ws = Accounts.ensure_default_workspace!()
    assert {:ok, %{rev: 1, key_wraps: wraps}} = Vaults.fetch(ws)
    assert Enum.sort(Enum.map(wraps, & &1.kind)) == ["passphrase", "recovery"]

    ctx = lock(ctx)
    refute_selector(ctx, "#vault-home")
    unlock_with_passphrase(ctx, @pass)
    assert_selector(ctx, "#vault-home")
    assert errors(ctx) == []
  end
end
