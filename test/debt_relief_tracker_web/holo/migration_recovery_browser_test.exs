defmodule DebtReliefTrackerWeb.Holo.MigrationRecoveryBrowserTest do
  @moduledoc """
  Real-Chromium recovery paths of the plaintext -> vault migration: the
  plaintext changes mid-migration (vault rebuilt), a reload while the status
  is :both, a damaged verification download and a busy finalize.
  """
  use DebtReliefTracker.BrowserCase

  import DebtReliefTracker.E2EEBrowser
  import DebtReliefTracker.MigrationHelpers

  alias DebtReliefTracker.{Accounts, Debts, Payments}
  alias DebtReliefTracker.E2EE.Migration

  @pass "correct horse battery staple 77"
  @marker "RECOV5521"

  setup do
    e2ee_on()

    for key <- [:migration_test_busy_finalize, :migration_test_corrupt_fetch] do
      ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:debt_relief_tracker, key) end)
    end

    ws = workspace()
    owner = Accounts.get_default_user!()
    %{debt: debt} = populate!(ws, owner, @marker)
    %{ws: ws, owner: owner, debt: debt}
  end

  defp plaintext_rows(table) do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(
        DebtReliefTracker.Repo.active_repo(),
        "SELECT count(*) FROM \"#{table}\"",
        []
      )

    n
  end

  defp log_new_payment(%{ws: ws, owner: owner, debt: debt}) do
    {:ok, _} =
      Payments.log_payment(ws, owner, Debts.get_debt!(ws, debt.id), %{
        "amount" => "42.00",
        "paid_on" => "2026-02-01",
        "note" => "late"
      })
  end

  defp assert_migrated(ctx, ws, payments) do
    ctx = click(ctx, "#migration-continue")
    assert_selector(ctx, "#vault-home")
    assert_text(ctx, "#vault-payments-count", "#{payments} payments")
    assert Migration.status(ws) == :vault_only
    assert plaintext_rows("debts") == 0
    assert plaintext_rows("payments") == 0
    ctx
  end

  test "(a) plaintext changed during the wizard: vault is rebuilt and the new payment survives",
       %{ws: ws} = ctx do
    ctx = ctx |> open_app() |> click("#migration-begin")
    assert_selector(ctx, "#vault-setup")
    log_new_payment(ctx)

    {ctx, _} = create_vault(ctx, @pass, done_selector: "#migration-done")
    assert_migrated(ctx, ws, 2)
    refute_in_database([@marker])
  end

  test "(b) reload while status is :both: unlock, re-export, verify, finish",
       %{ws: ws} = ctx do
    # every finalize is busy: the vault is created, the plaintext stays
    Application.put_env(:debt_relief_tracker, :migration_test_busy_finalize, 99)
    ctx = ctx |> open_app() |> click("#migration-begin")
    {ctx, _} = create_vault(ctx, @pass, done_selector: "#migration-progress")
    # the 1 s + 3 s + 9 s backoff runs out
    Process.sleep(15_000)
    assert_selector(ctx, "#migration-error")
    assert attr(ctx, "#migration-error", "data-reason") == "busy"
    assert Migration.status(ws) == :both

    Application.put_env(:debt_relief_tracker, :migration_test_busy_finalize, 0)

    # once the vault exists plaintext is frozen (E2EE.PlainGuard), so no write
    # can make the vault stale here
    assert {:error, :workspace_encrypted} =
             Payments.log_payment(ws, ctx.owner, Debts.get_debt!(ws, ctx.debt.id), %{
               "amount" => "42.00",
               "paid_on" => "2026-02-01",
               "note" => "late"
             })

    assert plaintext_rows("payments") == 1

    ctx = reload(ctx)
    ctx = unlock_with_passphrase(ctx, @pass)
    assert_selector(ctx, "#migration-done")
    assert_migrated(ctx, ws, 1)
  end

  test "(c) a damaged download deletes nothing; retry then succeeds", %{ws: ws} = ctx do
    Application.put_env(:debt_relief_tracker, :migration_test_corrupt_fetch, 1)
    ctx = ctx |> open_app() |> click("#migration-begin")
    {ctx, _} = create_vault(ctx, @pass, done_selector: "#migration-error")
    assert attr(ctx, "#migration-error", "data-reason") == "verification_mismatch"
    assert plaintext_rows("debts") == 1
    assert plaintext_rows("payments") == 1
    assert Migration.status(ws) == :both

    ctx = click(ctx, "#migration-retry")
    assert_selector(ctx, "#migration-done")
    assert_migrated(ctx, ws, 1)
  end

  test "(d) a busy finalize is retried by itself", %{ws: ws} = ctx do
    Application.put_env(:debt_relief_tracker, :migration_test_busy_finalize, 1)
    ctx = ctx |> open_app() |> click("#migration-begin")
    {ctx, _} = create_vault(ctx, @pass, done_selector: "#migration-done")
    assert_migrated(ctx, ws, 1)
  end
end
