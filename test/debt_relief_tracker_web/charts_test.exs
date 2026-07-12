defmodule DebtReliefTrackerWeb.ChartsTest do
  use ExUnit.Case, async: true

  alias DebtReliefTrackerWeb.Charts
  alias DebtReliefTracker.Planning
  alias DebtReliefTracker.Debts.Debt

  defp debt(attrs) do
    struct(
      %Debt{
        balance: Decimal.new("0"),
        apr: Decimal.new("0"),
        minimum_payment_floor: Decimal.new("0"),
        minimum_payment_rate: Decimal.new("0"),
        exclude_from_plan: false,
        status: :active
      },
      attrs
    )
  end

  describe "build/6 :comparison" do
    test "returns a bar config with an interest and a months dataset when there's data to compare" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("500"),
          fixed_payment: Decimal.new("100")
        ),
        debt(
          id: 2,
          type: :installment,
          balance: Decimal.new("500"),
          fixed_payment: Decimal.new("100")
        )
      ]

      strategies = Planning.compare_strategies(debts, Decimal.new("300"))

      {message, config} =
        Charts.build(:comparison, :cash_flow, strategies, debts, Decimal.new("300"), [])

      assert message == nil
      assert config.type == "bar"
      assert length(config.data.labels) == 3
      assert [%{label: "Total interest ($)"}, %{label: "Months to payoff"}] = config.data.datasets
    end

    test "returns a message instead of a config when there are no debts" do
      strategies = Planning.compare_strategies([], Decimal.new("300"))

      assert {"Add a debt to compare payoff strategies.", nil} =
               Charts.build(:comparison, :cash_flow, strategies, [], Decimal.new("300"), [])
    end
  end

  describe "build/6 :simulation" do
    test "returns a line config with one dataset per debt plus a Total line" do
      debts = [
        debt(
          id: 1,
          name: "A",
          type: :installment,
          balance: Decimal.new("300"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        ),
        debt(
          id: 2,
          name: "B",
          type: :installment,
          balance: Decimal.new("300"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      strategies = %{cash_flow: Planning.simulate(debts, Decimal.new("200"), :cash_flow)}

      {message, config} =
        Charts.build(:simulation, :cash_flow, strategies, debts, Decimal.new("200"), [])

      assert message == nil
      assert config.type == "line"
      labels = Enum.map(config.data.datasets, & &1.label)
      assert "Total" in labels
      assert "A" in labels
      assert "B" in labels
    end

    test "returns a message when the budget doesn't cover minimums" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("500")
        )
      ]

      strategies = %{cash_flow: Planning.simulate(debts, Decimal.new("10"), :cash_flow)}

      assert {message, nil} =
               Charts.build(:simulation, :cash_flow, strategies, debts, Decimal.new("10"), [])

      assert message =~ "budget"
    end
  end

  describe "build/6 :monthly_payments" do
    test "returns a stacked, filled line config with one dataset per debt" do
      debts = [
        debt(
          id: 1,
          name: "A",
          type: :installment,
          balance: Decimal.new("300"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        ),
        debt(
          id: 2,
          name: "B",
          type: :installment,
          balance: Decimal.new("300"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      strategies = %{cash_flow: Planning.simulate(debts, Decimal.new("200"), :cash_flow)}

      {message, config} =
        Charts.build(:monthly_payments, :cash_flow, strategies, debts, Decimal.new("200"), [])

      assert message == nil
      assert config.type == "line"
      assert config.options.scales.x.stacked == true
      assert config.options.scales.y.stacked == true
      labels = Enum.map(config.data.datasets, & &1.label)
      assert "A" in labels
      assert "B" in labels
      assert Enum.all?(config.data.datasets, & &1.fill)
    end

    test "returns a message when the budget doesn't cover minimums" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("500")
        )
      ]

      strategies = %{cash_flow: Planning.simulate(debts, Decimal.new("10"), :cash_flow)}

      assert {message, nil} =
               Charts.build(
                 :monthly_payments,
                 :cash_flow,
                 strategies,
                 debts,
                 Decimal.new("10"),
                 []
               )

      assert message =~ "budget"
    end
  end

  describe "build/6 :freed_cashflow" do
    test "returns a filled line config when there's a plan to project" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("300"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      {message, config} =
        Charts.build(:freed_cashflow, :cash_flow, %{}, debts, Decimal.new("100"), [])

      assert message == nil
      assert config.type == "line"
      assert [%{fill: true, label: "Monthly payment freed"}] = config.data.datasets
    end

    test "returns a message when there are no debts" do
      assert {message, nil} =
               Charts.build(:freed_cashflow, :cash_flow, %{}, [], Decimal.new("100"), [])

      assert message =~ "Add a debt"
    end
  end

  describe "build/6 :interest_breakdown" do
    test "returns a doughnut config splitting principal vs. interest" do
      payments = [
        %{principal_portion: Decimal.new("80.00"), interest_portion: Decimal.new("20.00")}
      ]

      {message, config} =
        Charts.build(:interest_breakdown, :cash_flow, %{}, [], Decimal.new("100"), payments)

      assert message == nil
      assert config.type == "doughnut"
      assert config.data.labels == ["Principal", "Interest"]
      assert [%{data: [80.0, 20.0]}] = config.data.datasets
    end

    test "returns a message when nothing's been paid yet" do
      assert {message, nil} =
               Charts.build(:interest_breakdown, :cash_flow, %{}, [], Decimal.new("100"), [])

      assert message =~ "Log a payment"
    end
  end

  describe "strategy_label/1 and debt_name/2" do
    test "labels every strategy" do
      assert Charts.strategy_label(:cash_flow) == "Cash flow"
      assert Charts.strategy_label(:snowball) == "Snowball"
      assert Charts.strategy_label(:avalanche) == "Avalanche"
    end

    test "looks up a debt's name by id, falling back to an empty string" do
      debts = [debt(id: 1, name: "Visa")]
      assert Charts.debt_name(debts, 1) == "Visa"
      assert Charts.debt_name(debts, 999) == ""
    end
  end
end
