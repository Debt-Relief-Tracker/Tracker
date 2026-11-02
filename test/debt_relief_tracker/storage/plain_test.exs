defmodule DebtReliefTracker.Storage.PlainTest do
  use DebtReliefTracker.DataCase

  alias DebtReliefTracker.{Accounts, Debts, Storage}
  alias DebtReliefTracker.Storage.Plain

  setup do
    %{workspace: Accounts.ensure_default_workspace!()}
  end

  @card %{
    name: "Visa",
    type: "revolving",
    balance: 450_000,
    apr_bp: 2499,
    minimum_payment_floor: 3500,
    minimum_payment_rate_bp: 200,
    credit_limit: 1_000_000
  }

  defp add_card(workspace, attrs \\ %{}) do
    {:ok, snapshot} = Plain.apply_change(workspace, nil, {:add_debt, Map.merge(@card, attrs)})
    List.last(snapshot.debts)
  end

  test "the configured adapter defaults to Plain", %{workspace: workspace} do
    assert Storage.adapter() == Plain
    assert {:ok, %{schema_version: 1}} = Storage.load(workspace)
  end

  test "load/1 returns a JSON-clean snapshot in cents and basis points", %{workspace: workspace} do
    debt = add_card(workspace)

    assert %{
             name: "Visa",
             type: "revolving",
             status: "active",
             balance: 450_000,
             apr_bp: 2499,
             minimum_payment_floor: 3500,
             minimum_payment_rate_bp: 200,
             credit_limit: 1_000_000,
             auto_log_mode: "off"
           } = debt

    {:ok, snapshot} = Plain.load(workspace)
    assert {:ok, _json} = Jason.encode(snapshot)
    assert snapshot.settings.currency == "USD"
    assert Enum.map(snapshot.activity, & &1.action) == ["debt_added"]
  end

  test "settings, debts, payments and retirement profiles carry updated_at for sync", %{
    workspace: workspace
  } do
    debt = add_card(workspace)

    {:ok, _} =
      Plain.apply_change(
        workspace,
        nil,
        {:log_payment, debt.id, %{amount: 10_000, paid_on: "2026-01-02"}}
      )

    {:ok, snapshot} =
      Plain.apply_change(
        workspace,
        nil,
        {:add_manual_retirement_profile,
         %{
           name: "Pat",
           current_age: 30,
           retirement_age: 65,
           current_retirement_savings: 0,
           monthly_retirement_contribution: 0,
           monthly_gross_income: 500_000,
           post_debt_investment_bp: 1000,
           expected_annual_return_bp: 700
         }}
      )

    rows = [
      snapshot.settings,
      hd(snapshot.debts),
      hd(snapshot.payments),
      hd(snapshot.retirement_profiles)
    ]

    for row <- rows do
      assert is_binary(row.updated_at)

      assert {:ok, _, _} =
               DateTime.from_iso8601(
                 row.updated_at <> if(String.ends_with?(row.updated_at, "Z"), do: "", else: "Z")
               )
    end

    assert {:ok, _json} = Jason.encode(snapshot)
  end

  test "snapshot values match what the Decimal contexts store", %{workspace: workspace} do
    debt = add_card(workspace)
    stored = Debts.get_debt!(workspace, debt.id)

    assert Decimal.equal?(stored.balance, Decimal.new("4500.00"))
    assert Decimal.equal?(stored.apr, Decimal.new("24.99"))
    assert Decimal.equal?(stored.minimum_payment_rate, Decimal.new("0.02"))
  end

  test "update, mark paid off and delete go through the contexts and log activity",
       %{workspace: workspace} do
    debt = add_card(workspace)

    assert {:ok, snapshot} =
             Plain.apply_change(workspace, nil, {:update_debt, debt.id, %{balance: 400_000}})

    assert Enum.find(snapshot.debts, &(&1.id == debt.id)).balance == 400_000

    assert {:ok, snapshot} = Plain.apply_change(workspace, nil, {:mark_paid_off, debt.id})
    assert Enum.find(snapshot.debts, &(&1.id == debt.id)).status == "paid_off"

    assert {:ok, snapshot} = Plain.apply_change(workspace, nil, {:delete_debt, debt.id})
    assert snapshot.debts == []

    assert Enum.map(snapshot.activity, & &1.action) |> Enum.sort() ==
             ["debt_added", "debt_deleted", "debt_paid_off", "debt_updated"]
  end

  test "log_payment reduces the balance by the principal portion", %{workspace: workspace} do
    debt = add_card(workspace)

    assert {:ok, snapshot} =
             Plain.apply_change(
               workspace,
               nil,
               {:log_payment, debt.id,
                %{
                  amount: 10_000,
                  principal_portion: 8000,
                  interest_portion: 2000,
                  paid_on: "2026-10-01"
                }}
             )

    assert Enum.find(snapshot.debts, &(&1.id == debt.id)).balance == 442_000

    assert [%{amount: 10_000, interest_portion: 2000, paid_on: "2026-10-01"}] = snapshot.payments
    assert "payment_logged" in Enum.map(snapshot.activity, & &1.action)
  end

  test "update_settings converts the budget to dollars", %{workspace: workspace} do
    assert {:ok, snapshot} =
             Plain.apply_change(workspace, nil, {:update_settings, %{monthly_budget: 150_000}})

    assert snapshot.settings.monthly_budget == 150_000
    stored = DebtReliefTracker.Settings.get_settings!(workspace)
    assert Decimal.equal?(stored.monthly_budget, Decimal.new("1500.00"))
  end

  test "validation failures come back as {:invalid, errors} and change nothing", %{
    workspace: workspace
  } do
    assert {:error, {:invalid, errors}} =
             Plain.apply_change(
               workspace,
               nil,
               {:add_debt, %{name: "Bad", type: "revolving", balance: 100, apr_bp: 100}}
             )

    assert Map.has_key?(errors, :minimum_payment_rate)
    assert {:ok, %{debts: []}} = Plain.load(workspace)
  end

  test "unknown fields are rejected rather than silently dropped", %{workspace: workspace} do
    assert {:error, {:invalid, %{bogus: _}}} =
             Plain.apply_change(workspace, nil, {:add_debt, Map.put(@card, :bogus, 1)})
  end

  test "unknown, malformed and other-workspace ids are :not_found", %{workspace: workspace} do
    other =
      DebtReliefTracker.Repo.insert!(%DebtReliefTracker.Accounts.Workspace{
        name: "Other",
        owner_user_id: Accounts.get_default_user!().id
      })

    foreign = add_card(other)

    for id <- [Ecto.UUID.generate(), "not-a-uuid", foreign.id] do
      assert {:error, :not_found} =
               Plain.apply_change(workspace, nil, {:update_debt, id, %{balance: 1}})

      assert {:error, :not_found} = Plain.apply_change(workspace, nil, {:delete_debt, id})
    end

    assert Debts.get_debt!(other, foreign.id)
  end

  test "an overpayment rolls back and leaves the snapshot unchanged", %{workspace: workspace} do
    debt = add_card(workspace)

    assert {:error, {:invalid, _}} =
             Plain.apply_change(
               workspace,
               nil,
               {:log_payment, debt.id, %{amount: 999_999_999, paid_on: "2026-10-01"}}
             )

    {:ok, snapshot} = Plain.load(workspace)
    assert Enum.find(snapshot.debts, &(&1.id == debt.id)).balance == 450_000
    assert snapshot.payments == []
  end
end
