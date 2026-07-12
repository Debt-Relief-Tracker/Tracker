defmodule DebtReliefTracker.PaymentsTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, ActivityLog, Debts, Payments}

  setup do
    workspace = Accounts.ensure_default_workspace!()

    {:ok, debt} =
      Debts.create_debt(workspace, nil, %{
        "name" => "Test Card",
        "type" => "revolving",
        "balance" => "1000.00",
        "apr" => "20.00",
        "minimum_payment_floor" => "25.00",
        "minimum_payment_rate" => "0.02"
      })

    %{workspace: workspace, debt: debt}
  end

  describe "log_payment/4" do
    test "reduces the debt balance by the principal portion and logs :payment_logged", %{
      workspace: workspace,
      debt: debt
    } do
      attrs = %{
        "amount" => "100.00",
        "principal_portion" => "80.00",
        "interest_portion" => "20.00",
        "paid_on" => ~D[2026-07-11]
      }

      assert {:ok, %{debt: updated, payment: payment}} =
               Payments.log_payment(workspace, nil, debt, attrs)

      assert Decimal.equal?(updated.balance, Decimal.new("920.00"))
      assert Decimal.equal?(payment.amount, Decimal.new("100.00"))

      actions = ActivityLog.list_recent(workspace) |> Enum.map(& &1.action)
      assert :payment_logged in actions
    end

    test "defaults the principal portion to the full amount when no split is given, and persists it on the payment",
         %{workspace: workspace, debt: debt} do
      attrs = %{"amount" => "50.00", "paid_on" => ~D[2026-07-11]}

      assert {:ok, %{debt: updated, payment: payment}} =
               Payments.log_payment(workspace, nil, debt, attrs)

      assert Decimal.equal?(updated.balance, Decimal.new("950.00"))

      # Regression: log_payment used to only apply the computed principal to
      # the debt's balance without persisting it back onto the payment row
      # itself, silently zeroing it out of lifetime interest/principal
      # reporting (docs/architecture -- the "log a payment" form only
      # collects "amount" by default, so this is the common case, not an
      # edge case).
      assert Decimal.equal?(payment.principal_portion, Decimal.new("50.00"))
    end

    test "rolls back when the payment would overdraw the balance", %{
      workspace: workspace,
      debt: debt
    } do
      attrs = %{"amount" => "5000.00", "paid_on" => ~D[2026-07-11]}

      assert {:error, changeset} = Payments.log_payment(workspace, nil, debt, attrs)
      assert %{balance: [_ | _]} = errors_on(changeset)

      reloaded = Debts.get_debt!(workspace, debt.id)
      assert Decimal.equal?(reloaded.balance, Decimal.new("1000.00"))
    end
  end
end
