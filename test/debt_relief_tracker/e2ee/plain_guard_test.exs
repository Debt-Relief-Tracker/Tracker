defmodule DebtReliefTracker.E2EE.PlainGuardTest do
  # Not async: OIDC config and the shared sandbox.
  use DebtReliefTracker.DataCase

  import DebtReliefTracker.E2EEHelpers
  import DebtReliefTracker.MigrationHelpers

  alias DebtReliefTracker.{ActivityLog, Debts, Payments, Settings}
  alias DebtReliefTracker.Storage.Plain

  @refused {:error, :workspace_encrypted}

  setup do
    enable_oidc()
    {owner, ws} = owner_ws("guard")
    %{owner: owner, ws: ws}
  end

  defp finalized!(ws, owner) do
    pop = populate!(ws, owner)
    create_vault!(ws)
    {:ok, export} = DebtReliefTracker.E2EE.Migration.export(ws, owner)
    {:ok, _} = fin(ws, owner, export.digest, [compact: false] ++ vopts(ws))
    pop
  end

  defp assert_nothing_left(ws) do
    assert %{debts: 0, payments: 0, activity: 0, profiles: 0} = table_counts(ws)
  end

  test "plaintext writes still work without a vault", %{ws: ws, owner: owner} do
    assert {:ok, _} =
             Debts.create_debt(ws, owner, %{
               "name" => "A",
               "type" => "revolving",
               "balance" => "1",
               "apr" => "5",
               "minimum_payment_rate" => "0.02",
               "minimum_payment_floor" => "25"
             })

    assert %{debts: 1, activity: 1} = table_counts(ws)
  end

  test "every context write refuses once the workspace has a vault", %{ws: ws, owner: owner} do
    %{debt: debt, profile: profile} = populate!(ws, owner)
    create_vault!(ws)
    before = table_counts(ws)

    assert @refused =
             Debts.create_debt(ws, owner, %{
               "name" => "B",
               "type" => "revolving",
               "balance" => "1"
             })

    assert @refused = Debts.update_debt(ws, owner, debt, %{"name" => "C"})
    assert @refused = Debts.mark_paid_off(ws, owner, debt)
    assert @refused = Debts.delete_debt(ws, owner, debt)
    assert @refused = Debts.mark_due_handled(debt, ~D[2026-01-01])

    assert @refused =
             Payments.log_payment(ws, owner, debt, %{"amount" => "1", "paid_on" => "2026-02-01"})

    assert @refused = ActivityLog.record(ws, owner, :debt_added, debt, %{})
    assert @refused = Settings.update_settings(Settings.get_settings!(ws), %{"currency" => "GBP"})
    assert @refused = Settings.add_manual_retirement_profile(ws, %{"name" => "X"})
    assert @refused = Settings.update_retirement_profile(profile, %{"name" => "Y"})
    assert @refused = Settings.delete_retirement_profile(profile)

    assert before == table_counts(ws)
    assert Debts.get_debt!(ws, debt.id).name == debt.name
    assert Settings.get_settings!(ws).currency == "EUR"
  end

  test "Storage.Plain refuses changes and leaves no rows after finalize", %{ws: ws, owner: owner} do
    %{debt: debt} = finalized!(ws, owner)
    assert_nothing_left(ws)

    attrs = %{name: "Late", type: "revolving", balance: 100, apr_bp: 1000}
    assert @refused = Plain.apply_change(ws, owner, {:add_debt, attrs})

    assert @refused = Plain.apply_change(ws, owner, {:update_settings, %{currency: "GBP"}})

    assert @refused =
             Plain.apply_change(ws, owner, {:add_manual_retirement_profile, %{name: "Z"}})

    assert_nothing_left(ws)
  end

  test "a refused write rolls back the whole transaction", %{ws: ws, owner: owner} do
    create_vault!(ws)

    assert @refused =
             DebtReliefTracker.Repo.transaction(fn ->
               DebtReliefTracker.E2EE.PlainGuard.transaction(ws.id, fn -> {:ok, :never} end)
               |> case do
                 {:error, reason} -> DebtReliefTracker.Repo.rollback(reason)
               end
             end)

    assert_nothing_left(ws)
    _ = owner
  end
end
