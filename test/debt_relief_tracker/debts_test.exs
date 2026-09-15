defmodule DebtReliefTracker.DebtsTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, ActivityLog, Debts}

  setup do
    %{workspace: Accounts.ensure_default_workspace!()}
  end

  describe "create_debt/3" do
    test "creates a revolving debt and logs :debt_added", %{workspace: workspace} do
      attrs = %{
        "name" => "Test Card",
        "type" => "revolving",
        "balance" => "1000.00",
        "apr" => "20.00",
        "minimum_payment_floor" => "25.00",
        "minimum_payment_rate" => "0.02"
      }

      assert {:ok, debt} = Debts.create_debt(workspace, nil, attrs)
      assert debt.name == "Test Card"
      assert debt.status == :active

      [entry] = ActivityLog.list_recent(workspace)
      assert entry.action == :debt_added
      assert entry.debt_id == debt.id
    end

    test "requires minimum_payment_rate for revolving debts", %{workspace: workspace} do
      attrs = %{"name" => "Bad Card", "type" => "revolving", "balance" => "100", "apr" => "10"}

      assert {:error, changeset} = Debts.create_debt(workspace, nil, attrs)
      assert %{minimum_payment_rate: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires fixed_payment for installment debts", %{workspace: workspace} do
      attrs = %{"name" => "Bad Loan", "type" => "installment", "balance" => "100", "apr" => "5"}

      assert {:error, changeset} = Debts.create_debt(workspace, nil, attrs)
      assert %{fixed_payment: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires due_day once auto_log_mode is enabled", %{workspace: workspace} do
      attrs = %{
        "name" => "Auto Loan",
        "type" => "installment",
        "balance" => "1000",
        "apr" => "5",
        "fixed_payment" => "100",
        "auto_log_mode" => "confirm"
      }

      assert {:error, changeset} = Debts.create_debt(workspace, nil, attrs)
      assert %{due_day: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects auto_log_mode on a revolving debt", %{workspace: workspace} do
      attrs = %{
        "name" => "Bad Card",
        "type" => "revolving",
        "balance" => "100",
        "apr" => "10",
        "minimum_payment_rate" => "0.02",
        "auto_log_mode" => "confirm",
        "due_day" => "15"
      }

      assert {:error, changeset} = Debts.create_debt(workspace, nil, attrs)
      assert %{auto_log_mode: ["is only available for installment debts"]} = errors_on(changeset)
    end
  end

  describe "mark_paid_off/3" do
    test "flips status and stamps paid_off_at, logging :debt_paid_off", %{workspace: workspace} do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Almost Done",
          "type" => "installment",
          "balance" => "10.00",
          "apr" => "5.00",
          "fixed_payment" => "10.00"
        })

      assert {:ok, paid_off} = Debts.mark_paid_off(workspace, nil, debt)
      assert paid_off.status == :paid_off
      assert paid_off.paid_off_at

      actions = ActivityLog.list_recent(workspace) |> Enum.map(& &1.action)
      assert :debt_paid_off in actions
    end
  end

  describe "delete_debt/3" do
    test "removes the debt and logs :debt_deleted", %{workspace: workspace} do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Unwanted Card",
          "type" => "revolving",
          "balance" => "100.00",
          "apr" => "10.00",
          "minimum_payment_floor" => "25.00",
          "minimum_payment_rate" => "0.02"
        })

      assert {:ok, _deleted} = Debts.delete_debt(workspace, nil, debt)
      assert Debts.list_debts(workspace) == []

      entry = ActivityLog.list_recent(workspace) |> Enum.find(&(&1.action == :debt_deleted))
      assert entry
      assert entry.debt_id == nil
      assert entry.metadata["name"] == "Unwanted Card"
    end

    test "also deletes any payments logged against the debt", %{workspace: workspace} do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Card",
          "type" => "installment",
          "balance" => "500.00",
          "apr" => "0.00",
          "fixed_payment" => "100.00"
        })

      {:ok, _} =
        DebtReliefTracker.Payments.log_payment(workspace, nil, debt, %{
          "amount" => "100.00",
          "paid_on" => ~D[2026-07-01]
        })

      assert {:ok, _} = Debts.delete_debt(workspace, nil, debt)
      assert DebtReliefTracker.Payments.list_payments_for_debt(debt) == []
    end
  end

  describe "reconcile_balance/5" do
    test "logs the gap as a payment and resets the statement baseline", %{workspace: workspace} do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Card",
          "type" => "revolving",
          "balance" => "1000.00",
          "apr" => "36.5",
          "minimum_payment_floor" => "25.00",
          "minimum_payment_rate" => "0.02",
          "statement_balance" => "1000.00",
          "statement_date" => ~D[2026-07-01]
        })

      # 30 days at 36.5% APR (0.1%/day) accrues ~30 of estimated interest,
      # so the estimated balance just before reconciling is ~1030.
      assert {:ok, updated} =
               Debts.reconcile_balance(workspace, nil, debt, "980.00", ~D[2026-07-31])

      assert Decimal.equal?(updated.balance, Decimal.new("980.00"))
      assert Decimal.equal?(updated.statement_balance, Decimal.new("980.00"))
      assert updated.statement_date == ~D[2026-07-31]

      [payment] = DebtReliefTracker.Payments.list_payments_for_debt(updated)
      assert Decimal.equal?(payment.amount, Decimal.new("50.0"))
      assert Decimal.equal?(payment.interest_portion, Decimal.new("30.0"))
    end

    test "when the new balance is higher than estimated, only resets the baseline (no payment)",
         %{
           workspace: workspace
         } do
      {:ok, debt} =
        Debts.create_debt(workspace, nil, %{
          "name" => "Card",
          "type" => "revolving",
          "balance" => "1000.00",
          "apr" => "36.5",
          "minimum_payment_floor" => "25.00",
          "minimum_payment_rate" => "0.02"
        })

      assert {:ok, updated} =
               Debts.reconcile_balance(workspace, nil, debt, "1200.00", ~D[2026-07-31])

      assert Decimal.equal?(updated.balance, Decimal.new("1200.00"))
      assert DebtReliefTracker.Payments.list_payments_for_debt(updated) == []
    end
  end

  describe "seed_placeholders_if_empty!/1" do
    test "seeds example debts only when the workspace has none", %{workspace: workspace} do
      assert Debts.list_debts(workspace) == []

      Debts.seed_placeholders_if_empty!(workspace)
      seeded = Debts.list_debts(workspace)
      assert length(seeded) == 3

      Debts.seed_placeholders_if_empty!(workspace)
      assert Debts.list_debts(workspace) |> length() == 3
    end
  end
end
