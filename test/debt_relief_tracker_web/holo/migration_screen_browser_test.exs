defmodule DebtReliefTrackerWeb.Holo.MigrationScreenBrowserTest do
  @moduledoc """
  Real-Chromium happy path of the one-time plaintext -> encrypted migration:
  existing plaintext + E2EE on -> migration screen -> setup wizard -> verified
  migration -> unlocked dashboard, with no plaintext left on the server.
  """
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.E2EEBrowser
  import DebtReliefTracker.MigrationHelpers
  import DebtReliefTracker.BrowserExtras, only: [errors: 1]

  alias DebtReliefTracker.{Accounts, Debts}
  alias DebtReliefTracker.E2EE.Migration

  @pass "correct horse battery staple 77"
  @marker "MIGMARK9271"

  setup do
    e2ee_on()
    :ok
  end

  test "an existing plaintext workspace is migrated to a vault and the plaintext is deleted",
       ctx do
    ws = workspace()
    owner = Accounts.get_default_user!()
    populate!(ws, owner, @marker)

    {:ok, _} =
      Debts.create_debt(ws, owner, %{
        "name" => "Second loan",
        "type" => "revolving",
        "balance" => "500.00",
        "apr" => "10.00",
        "minimum_payment_floor" => "25",
        "minimum_payment_rate" => "0.02"
      })

    assert Migration.status(ws) == :plaintext_only

    ctx = open_app(ctx)
    assert_selector(ctx, "#migration-screen")
    refute_selector(ctx, "#migration-members")
    ctx = click(ctx, "#migration-begin")

    # the existing wizard, then the migration runs by itself
    {ctx, _key} = create_vault(ctx, @pass, done_selector: "#migration-done")
    assert_selector(ctx, "#migration-done")
    ctx = click(ctx, "#migration-continue")
    assert_selector(ctx, "#vault-home")
    assert_text(ctx, "#vault-debts", @marker)
    assert_text(ctx, "#vault-debts", "Second loan")
    assert_text(ctx, "#vault-payments-count", "1 payments")

    # nothing readable is left on the server
    assert Migration.status(ws) == :vault_only
    refute_in_database([@marker, "Second loan"])

    for table <- ~w(debts payments activity_logs retirement_profiles) do
      %{rows: [[n]]} =
        Ecto.Adapters.SQL.query!(
          DebtReliefTracker.Repo.active_repo(),
          "SELECT count(*) FROM \"#{table}\"",
          []
        )

      assert n == 0, "#{table} still has #{n} plaintext rows"
    end

    # the settings row shell stays, but every value is back to its default
    assert Migration.status(ws) == :vault_only
    assert DebtReliefTracker.Settings.get_settings!(ws).monthly_budget in [nil, Decimal.new(0)]

    assert server_vault().rev >= 1

    ctx = lock(ctx)
    unlock_with_passphrase(ctx, @pass)
    assert_selector(ctx, "#vault-home")
    assert_text(ctx, "#vault-debts", @marker)
    assert_text(ctx, "#vault-debts", "Second loan")
    assert errors(ctx) == []
  end
end
