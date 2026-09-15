defmodule DebtReliefTracker.DuePaymentsTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, ActivityLog, Debts, DuePayments}

  setup do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, debt} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Auto Loan",
        "type" => "installment",
        "balance" => "1000.00",
        "apr" => "5.00",
        "fixed_payment" => "100.00",
        "auto_log_mode" => "confirm",
        "due_day" => "15"
      })

    %{workspace: workspace, debt: debt}
  end

  describe "due_debts/2" do
    test "returns only debts with an unhandled due payment", %{debt: due_debt} do
      {:ok, not_due_debt} =
        Debts.update_debt(Accounts.ensure_default_workspace!(), nil, due_debt, %{
          "last_due_handled_on" => "2026-07-15"
        })

      assert DuePayments.due_debts([due_debt], ~D[2026-07-20]) == [due_debt]
      assert DuePayments.due_debts([not_due_debt], ~D[2026-07-20]) == []
    end
  end

  describe "post_due_payment/4" do
    test "logs a payment with logged_by_user_id: nil and tags it :payment_auto_logged when user is nil",
         %{workspace: workspace, debt: debt} do
      assert {:ok, %{payment: payment, debt: updated}} =
               DuePayments.post_due_payment(workspace, nil, debt, ~D[2026-07-20])

      assert payment.logged_by_user_id == nil
      assert Decimal.equal?(payment.amount, Decimal.new("100.00"))
      assert Decimal.equal?(updated.balance, Decimal.new("900.00"))
      assert updated.last_due_handled_on == ~D[2026-07-15]

      [entry | _] = ActivityLog.list_recent(workspace)
      assert entry.action == :payment_auto_logged
    end

    test "tags the entry :payment_logged when posted on behalf of a real user", %{
      workspace: workspace,
      debt: debt
    } do
      user = Accounts.get_or_create_user_from_oidc!(%{"sub" => "a", "email" => "a@example.com"})

      assert {:ok, _} = DuePayments.post_due_payment(workspace, user, debt, ~D[2026-07-20])

      [entry | _] = ActivityLog.list_recent(workspace)
      assert entry.action == :payment_logged
    end

    test "returns {:error, :not_due} and writes nothing when called when the debt isn't actually due",
         %{workspace: workspace, debt: debt} do
      {:ok, handled} = Debts.mark_due_handled(debt, ~D[2026-07-15])

      assert DuePayments.post_due_payment(workspace, nil, handled, ~D[2026-07-20]) ==
               {:error, :not_due}

      assert Enum.map(ActivityLog.list_recent(workspace), & &1.action) == [:debt_added]
    end
  end

  describe "skip_due_payment/4" do
    test "marks the cycle handled without logging a payment", %{workspace: workspace, debt: debt} do
      assert {:ok, updated} = DuePayments.skip_due_payment(workspace, nil, debt, ~D[2026-07-20])

      assert updated.last_due_handled_on == ~D[2026-07-15]

      reloaded_balance =
        Debts.list_debts(workspace) |> Enum.find(&(&1.id == debt.id)) |> Map.fetch!(:balance)

      assert Decimal.equal?(reloaded_balance, debt.balance)

      [entry | _] = ActivityLog.list_recent(workspace)
      assert entry.action == :due_payment_skipped
    end
  end
end
