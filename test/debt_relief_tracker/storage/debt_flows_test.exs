defmodule DebtReliefTracker.Storage.DebtFlowsTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, Debts}
  alias DebtReliefTracker.Storage.Plain

  setup do
    %{workspace: Accounts.ensure_default_workspace!()}
  end

  defp add(workspace, attrs) do
    {:ok, debt} = Debts.create_debt(workspace, nil, attrs)
    debt
  end

  defp loan(workspace, extra \\ %{}) do
    add(
      workspace,
      Map.merge(
        %{
          "name" => "Auto Loan Due",
          "type" => "installment",
          "balance" => "1000.00",
          "apr" => "5.00",
          "fixed_payment" => "150.00",
          "auto_log_mode" => "confirm",
          "due_day" => to_string(Date.utc_today().day)
        },
        extra
      )
    )
  end

  defp actions(snapshot), do: Enum.map(snapshot.activity, & &1.action)

  describe "{:reconcile_balance, id, cents}" do
    test "reconciles a revolving debt to the observed balance", %{workspace: workspace} do
      card =
        add(workspace, %{
          "name" => "Visa",
          "type" => "revolving",
          "balance" => "4500.00",
          "apr" => "0",
          "minimum_payment_floor" => "35.00",
          "minimum_payment_rate" => "0.02"
        })

      assert {:ok, snapshot} =
               Plain.apply_change(workspace, nil, {:reconcile_balance, card.id, 400_000})

      assert Enum.find(snapshot.debts, &(&1.id == card.id)).balance == 400_000
      assert Decimal.equal?(Debts.get_debt!(workspace, card.id).balance, Decimal.new("4000.00"))
      assert "payment_logged" in actions(snapshot)
    end

    test "unknown debts are :not_found", %{workspace: workspace} do
      assert {:error, :not_found} =
               Plain.apply_change(workspace, nil, {:reconcile_balance, Ecto.UUID.generate(), 100})
    end
  end

  describe "{:handle_due, id, decision, cycle_iso}" do
    test ":post logs the fixed payment and stamps the cycle (auto-logged activity)", %{
      workspace: workspace
    } do
      debt = loan(workspace)
      cycle = Date.to_iso8601(Date.utc_today())

      assert {:ok, snapshot} =
               Plain.apply_change(workspace, nil, {:handle_due, debt.id, :post, cycle})

      loaded = Enum.find(snapshot.debts, &(&1.id == debt.id))
      assert loaded.balance == 85_000
      assert loaded.last_due_handled_on == cycle
      assert "payment_auto_logged" in actions(snapshot)
      assert [%{amount: 15_000, paid_on: ^cycle}] = snapshot.payments
    end

    test ":skip stamps the cycle without a payment (due_payment_skipped)", %{workspace: workspace} do
      debt = loan(workspace)
      cycle = Date.to_iso8601(Date.utc_today())

      assert {:ok, snapshot} =
               Plain.apply_change(workspace, nil, {:handle_due, debt.id, :skip, cycle})

      loaded = Enum.find(snapshot.debts, &(&1.id == debt.id))
      assert loaded.balance == 100_000
      assert loaded.last_due_handled_on == cycle
      assert snapshot.payments == []
      assert "due_payment_skipped" in actions(snapshot)
    end

    test "a cycle that was already handled is :not_due and writes nothing", %{
      workspace: workspace
    } do
      debt = loan(workspace)
      cycle = Date.to_iso8601(Date.utc_today())
      {:ok, _} = Plain.apply_change(workspace, nil, {:handle_due, debt.id, :post, cycle})

      assert {:error, :not_due} =
               Plain.apply_change(workspace, nil, {:handle_due, debt.id, :post, cycle})

      assert Decimal.equal?(Debts.get_debt!(workspace, debt.id).balance, Decimal.new("850.00"))
    end

    test "a future date, a non-due-date, junk, or an off-mode debt is :not_due", %{
      workspace: workspace
    } do
      debt = loan(workspace)
      tomorrow = Date.to_iso8601(Date.add(Date.utc_today(), 1))
      wrong_day = Date.to_iso8601(Date.add(Date.utc_today(), -1))

      for cycle <- [tomorrow, wrong_day, "not-a-date"] do
        assert {:error, :not_due} =
                 Plain.apply_change(workspace, nil, {:handle_due, debt.id, :post, cycle})
      end

      off = loan(workspace, %{"auto_log_mode" => "off", "name" => "Off Loan"})

      assert {:error, :not_due} =
               Plain.apply_change(
                 workspace,
                 nil,
                 {:handle_due, off.id, :post, Date.to_iso8601(Date.utc_today())}
               )
    end

    test "unknown debts are :not_found", %{workspace: workspace} do
      assert {:error, :not_found} =
               Plain.apply_change(
                 workspace,
                 nil,
                 {:handle_due, Ecto.UUID.generate(), :post, Date.to_iso8601(Date.utc_today())}
               )
    end
  end
end
