defmodule DebtReliefTracker.DuePayments.SchedulerTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, ActivityLog, Debts}
  alias DebtReliefTracker.DuePayments.Scheduler

  # run_due_checks/0 iterates every workspace via Accounts.list_workspaces/0
  # and Ecto.Adapters.SQL.Sandbox in :manual mode only shares the current
  # test's connection with processes started via allow/3 -- but
  # run_due_checks/0 runs in the test process itself (no timer involved),
  # so no extra allowance is needed here.

  setup do
    %{workspace: Accounts.ensure_default_workspace!()}
  end

  test "posts due automatic-mode installment debts and broadcasts", %{workspace: workspace} do
    {:ok, debt} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Auto Loan",
        "type" => "installment",
        "balance" => "1000.00",
        "apr" => "5.00",
        "fixed_payment" => "100.00",
        "auto_log_mode" => "automatic",
        "due_day" => to_string(Date.utc_today().day)
      })

    Phoenix.PubSub.subscribe(DebtReliefTracker.PubSub, "workspace:#{workspace.id}")

    assert Scheduler.run_due_checks() == :ok

    reloaded = Debts.get_debt!(workspace, debt.id)
    assert Decimal.equal?(reloaded.balance, Decimal.new("900.00"))
    assert reloaded.last_due_handled_on == Date.utc_today()

    assert_received {:due_payment_posted, debt_id}
    assert debt_id == debt.id

    [entry | _] = ActivityLog.list_recent(workspace)
    assert entry.action == :payment_auto_logged
  end

  test "leaves :confirm-mode and :off debts alone", %{workspace: workspace} do
    {:ok, confirm_debt} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Confirm Loan",
        "type" => "installment",
        "balance" => "500.00",
        "apr" => "5.00",
        "fixed_payment" => "50.00",
        "auto_log_mode" => "confirm",
        "due_day" => to_string(Date.utc_today().day)
      })

    {:ok, off_debt} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Off Loan",
        "type" => "installment",
        "balance" => "500.00",
        "apr" => "5.00",
        "fixed_payment" => "50.00"
      })

    assert Scheduler.run_due_checks() == :ok

    assert Decimal.equal?(
             Debts.get_debt!(workspace, confirm_debt.id).balance,
             Decimal.new("500.00")
           )

    assert Decimal.equal?(Debts.get_debt!(workspace, off_debt.id).balance, Decimal.new("500.00"))
  end
end
