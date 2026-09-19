defmodule DebtReliefTrackerWeb.ChartsTest do
  use ExUnit.Case, async: true

  alias DebtReliefTrackerWeb.Charts
  alias DebtReliefTracker.Planning
  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Settings.Setting

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

  defp setting(attrs) do
    struct(
      %Setting{
        current_retirement_savings: Decimal.new("0"),
        monthly_retirement_contribution: Decimal.new("0"),
        monthly_gross_income: Decimal.new("0"),
        post_debt_investment_pct: Decimal.new("15.0"),
        expected_annual_return_pct: Decimal.new("7.0")
      },
      attrs
    )
  end

  describe "build/7 :comparison" do
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
        Charts.build(:comparison, :cash_flow, strategies, debts, Decimal.new("300"), [], %{})

      assert message == nil
      assert config.type == "bar"
      assert length(config.data.labels) == 3
      assert [%{label: "Total interest ($)"}, %{label: "Months to payoff"}] = config.data.datasets
    end

    test "returns a message instead of a config when there are no debts" do
      strategies = Planning.compare_strategies([], Decimal.new("300"))

      assert {"Add a debt to compare payoff strategies.", nil} =
               Charts.build(:comparison, :cash_flow, strategies, [], Decimal.new("300"), [], %{})
    end

    test "returns a budget message, not the no-debts message, when a debt exists but the budget doesn't cover minimums" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("500")
        )
      ]

      strategies = Planning.compare_strategies(debts, Decimal.new("10"))

      assert {message, nil} =
               Charts.build(
                 :comparison,
                 :cash_flow,
                 strategies,
                 debts,
                 Decimal.new("10"),
                 [],
                 %{}
               )

      assert message =~ "budget"
      refute message =~ "Add a debt"
    end
  end

  describe "build/7 :simulation" do
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
        Charts.build(:simulation, :cash_flow, strategies, debts, Decimal.new("200"), [], %{})

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
               Charts.build(
                 :simulation,
                 :cash_flow,
                 strategies,
                 debts,
                 Decimal.new("10"),
                 [],
                 %{}
               )

      assert message =~ "budget"
    end
  end

  describe "build/7 :monthly_payments" do
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
        Charts.build(
          :monthly_payments,
          :cash_flow,
          strategies,
          debts,
          Decimal.new("200"),
          [],
          %{}
        )

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
                 [],
                 %{}
               )

      assert message =~ "budget"
    end
  end

  describe "build/7 :freed_cashflow" do
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
        Charts.build(:freed_cashflow, :cash_flow, %{}, debts, Decimal.new("100"), [], %{})

      assert message == nil
      assert config.type == "line"
      assert [%{fill: true, label: "Monthly payment freed"}] = config.data.datasets
    end

    test "returns a message when there are no debts" do
      assert {message, nil} =
               Charts.build(:freed_cashflow, :cash_flow, %{}, [], Decimal.new("100"), [], %{})

      assert message =~ "Add a debt"
    end
  end

  describe "build/7 :interest_breakdown" do
    test "returns a doughnut config splitting principal vs. interest" do
      payments = [
        %{principal_portion: Decimal.new("80.00"), interest_portion: Decimal.new("20.00")}
      ]

      {message, config} =
        Charts.build(:interest_breakdown, :cash_flow, %{}, [], Decimal.new("100"), payments, %{})

      assert message == nil
      assert config.type == "doughnut"
      assert config.data.labels == ["Principal", "Interest"]
      assert [%{data: [80.0, 20.0]}] = config.data.datasets
    end

    test "returns a message when nothing's been paid yet" do
      assert {message, nil} =
               Charts.build(:interest_breakdown, :cash_flow, %{}, [], Decimal.new("100"), [], %{})

      assert message =~ "Log a payment"
    end
  end

  describe "build/7 :retirement_roadmap" do
    test "returns a message when the retirement profile isn't set up yet" do
      assert {message, nil} =
               Charts.build(
                 :retirement_roadmap,
                 :cash_flow,
                 %{},
                 [],
                 Decimal.new("100"),
                 [],
                 setting(current_age: nil, retirement_age: nil)
               )

      assert message =~ "retirement profile"
    end

    test "returns a message when retirement age isn't after current age" do
      assert {message, nil} =
               Charts.build(
                 :retirement_roadmap,
                 :cash_flow,
                 %{},
                 [],
                 Decimal.new("100"),
                 [],
                 setting(current_age: 40, retirement_age: 40)
               )

      assert message =~ "Retirement age must be after current age"
    end

    test "returns a baseline plus one dataset per strategy when the profile is set" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("300"),
          apr: Decimal.new("0"),
          fixed_payment: Decimal.new("100")
        )
      ]

      settings =
        setting(
          current_age: 30,
          retirement_age: 32,
          monthly_retirement_contribution: Decimal.new("100"),
          monthly_gross_income: Decimal.new("4000")
        )

      {message, config} =
        Charts.build(
          :retirement_roadmap,
          :cash_flow,
          %{},
          debts,
          Decimal.new("100"),
          [],
          settings
        )

      assert message == nil
      assert config.type == "line"
      assert config.data.labels == [30, 31, 32]

      # Lines are drawn with pointRadius: 0, so without index-mode/non-intersect
      # interaction, hovering would almost never land exactly on a point and
      # tooltips (showing the value per age) would never fire.
      assert config.options.interaction == %{mode: "index", intersect: false}

      labels = Enum.map(config.data.datasets, & &1.label)
      assert "Baseline (no debt strategy)" in labels
      assert "Cash flow" in labels
      assert "Snowball" in labels
      assert "Avalanche" in labels
      assert length(config.data.datasets) == 4

      # Balances and contributions are plain floats (not %Decimal{}), one
      # per label -- Chart.js needs numeric, JSON-serializable values, and
      # `Jason` would otherwise encode a raw Decimal as a *string*.
      for dataset <- config.data.datasets do
        assert length(dataset.data) == 3
        assert Enum.all?(dataset.data, &is_float/1)
        assert length(dataset.monthlyContribution) == 3
        assert Enum.all?(dataset.monthlyContribution, &is_float/1)
      end

      # Debt (balance 300, fixed_payment 100, 0% APR) is paid off by month 3
      # at this $100 budget -- before this 2-year horizon's first label past
      # "now" -- so every strategy should already show the post-debt
      # contribution (15% of $4000 = $600/mo) at both later labels.
      cash_flow = Enum.find(config.data.datasets, &(&1.label == "Cash flow"))
      assert cash_flow.monthlyContribution == [100.0, 600.0, 600.0]

      baseline = Enum.find(config.data.datasets, &(&1.label == "Baseline (no debt strategy)"))
      assert baseline.monthlyContribution == [100.0, 100.0, 100.0]
    end

    test "drops a strategy's dataset when its plan errors, keeping the baseline" do
      debts = [
        debt(
          id: 1,
          type: :installment,
          balance: Decimal.new("1000"),
          fixed_payment: Decimal.new("500")
        )
      ]

      settings = setting(current_age: 30, retirement_age: 32)

      {message, config} =
        Charts.build(:retirement_roadmap, :cash_flow, %{}, debts, Decimal.new("10"), [], settings)

      assert message == nil
      assert [%{label: "Baseline (no debt strategy)"}] = config.data.datasets
    end

    test "with no debts, every strategy line matches every other strategy line and diverges from baseline" do
      settings =
        setting(
          current_age: 30,
          retirement_age: 32,
          monthly_retirement_contribution: Decimal.new("100"),
          monthly_gross_income: Decimal.new("4000"),
          post_debt_investment_pct: Decimal.new("15.0")
        )

      {nil, config} =
        Charts.build(:retirement_roadmap, :cash_flow, %{}, [], Decimal.new("100"), [], settings)

      [baseline | strategy_datasets] = config.data.datasets
      assert baseline.label == "Baseline (no debt strategy)"

      strategy_series = Enum.map(strategy_datasets, & &1.data)
      assert Enum.uniq(strategy_series) == [hd(strategy_series)]
      refute hd(strategy_series) == baseline.data
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
