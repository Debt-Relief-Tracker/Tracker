defmodule DebtReliefTracker.Engine.ChartsTest do
  # Ports test/debt_relief_tracker_web/charts_test.exs to the integer engine
  # (same scenarios, cents instead of Decimal), adds the regressions the
  # LiveView builder still had, and checks parity against the Decimal
  # `DebtReliefTrackerWeb.Charts` within the documented sub-cent drift.
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Engine.Charts
  alias DebtReliefTracker.Engine.Planning

  @budget_message "Your monthly budget doesn't cover minimum payments yet -- increase it above."

  defp debt(attrs) do
    Map.merge(
      %{
        id: 1,
        name: "",
        type: :installment,
        status: :active,
        exclude_from_plan: false,
        balance: 0,
        apr_bp: 0,
        fixed_payment: nil,
        minimum_payment_floor: 0,
        minimum_payment_rate_bp: 0,
        credit_limit: nil,
        statement_balance: nil,
        statement_days: nil
      },
      Map.new(attrs)
    )
  end

  defp two_installments do
    [
      debt(id: 1, name: "A", balance: 30_000, fixed_payment: 10_000),
      debt(id: 2, name: "B", balance: 30_000, fixed_payment: 10_000)
    ]
  end

  defp unaffordable, do: [debt(id: 1, balance: 100_000, fixed_payment: 50_000)]

  defp build(type, strategies, debts, budget, payments \\ [], profiles \\ []),
    do: Charts.build(type, :cash_flow, strategies, debts, budget, payments, profiles)

  describe "build/7 :comparison" do
    test "a bar config with an interest and a months dataset when there's data to compare" do
      debts = [
        debt(id: 1, balance: 50_000, fixed_payment: 10_000),
        debt(id: 2, balance: 50_000, fixed_payment: 10_000)
      ]

      {nil, config} =
        build(:comparison, Planning.compare_strategies(debts, 30_000), debts, 30_000)

      assert config.type == "bar"
      assert config.data.labels == ["Cash flow", "Snowball", "Avalanche"]
      assert [%{label: "Total interest ($)"}, %{label: "Months to payoff"}] = config.data.datasets
      assert [_, %{data: [4, 4, 4]}] = config.data.datasets
    end

    test "a message instead of a config when there are no debts" do
      assert {"Add a debt to compare payoff strategies.", nil} =
               build(:comparison, Planning.compare_strategies([], 30_000), [], 30_000)
    end

    test "a budget message, not the no-debts message, when the budget doesn't cover minimums" do
      debts = unaffordable()
      {message, nil} = build(:comparison, Planning.compare_strategies(debts, 1_000), debts, 1_000)

      assert message =~ "budget"
      refute message =~ "Add a debt"
    end
  end

  describe "build/7 :simulation" do
    test "a line config with one dataset per debt plus a dashed Total line" do
      debts = two_installments()
      strategies = %{cash_flow: Planning.simulate(debts, 20_000, :cash_flow)}

      {nil, config} = build(:simulation, strategies, debts, 20_000)

      assert config.type == "line"
      assert ["Total", "A", "B"] = Enum.map(config.data.datasets, & &1.label)
      assert config.data.labels == ["Month 1", "Month 2", "Month 3"]
      [total, a, b] = config.data.datasets
      assert total.data == ["400.00", "200.00", "0.00"]
      assert a.data == ["200.00", "100.00", "0.00"]
      assert b.data == ["200.00", "100.00", "0.00"]
      assert total.borderDash == [6, 3]
    end

    test "re-simulates when the caller didn't pass the strategy's result" do
      debts = two_installments()
      assert {nil, %{type: "line"}} = build(:simulation, %{}, debts, 20_000)
    end

    test "a message when the budget doesn't cover minimums" do
      debts = unaffordable()
      strategies = %{cash_flow: Planning.simulate(debts, 1_000, :cash_flow)}
      assert {@budget_message, nil} = build(:simulation, strategies, debts, 1_000)
    end
  end

  describe "build/7 :monthly_payments" do
    test "a stacked, filled line config with one dataset per debt" do
      debts = two_installments()
      strategies = %{cash_flow: Planning.simulate(debts, 20_000, :cash_flow)}

      {nil, config} = build(:monthly_payments, strategies, debts, 20_000)

      assert config.type == "line"
      assert config.options.scales.x.stacked == true
      assert config.options.scales.y.stacked == true
      assert ["A", "B"] = Enum.map(config.data.datasets, & &1.label)
      assert Enum.all?(config.data.datasets, & &1.fill)
      assert hd(config.data.datasets).data == ["100.00", "100.00", "100.00"]
    end

    test "a message when the budget doesn't cover minimums" do
      debts = unaffordable()
      strategies = %{cash_flow: Planning.simulate(debts, 1_000, :cash_flow)}
      assert {@budget_message, nil} = build(:monthly_payments, strategies, debts, 1_000)
    end
  end

  describe "build/7 :freed_cashflow" do
    test "a filled line config when there's a plan to project" do
      debts = [debt(id: 1, balance: 30_000, fixed_payment: 10_000)]

      {nil, config} = build(:freed_cashflow, %{}, debts, 10_000)

      assert config.type == "line"
      assert [%{fill: true, label: "Monthly payment freed", data: data}] = config.data.datasets
      assert data == ["0.00", "0.00", "100.00"]
    end

    test "matches Engine.Planning.freed_cashflow_over_time/3" do
      debts = two_installments()
      {:ok, freed} = Planning.freed_cashflow_over_time(debts, 25_000, :snowball)

      {nil, config} =
        Charts.build(:freed_cashflow, :snowball, %{}, debts, 25_000, [], [])

      assert hd(config.data.datasets).data == Enum.map(freed, &Charts.dollars(&1.freed))
    end

    test "a message when there are no debts" do
      assert {message, nil} = build(:freed_cashflow, %{}, [], 10_000)
      assert message =~ "Add a debt"
    end

    # The LiveView builder still reports this as "Add a debt to see cash flow
    # freed over time." -- the same mislabel fixed for comparison in 216bcc9.
    test "a budget message (not 'Add a debt') when the budget doesn't cover minimums" do
      assert {@budget_message, nil} = build(:freed_cashflow, %{}, unaffordable(), 1_000)
    end
  end

  describe "build/7 :interest_breakdown" do
    test "a doughnut config splitting principal vs. interest" do
      payments = [%{principal_portion: 8_000, interest_portion: 2_000}]

      {nil, config} = build(:interest_breakdown, %{}, [], 10_000, payments)

      assert config.type == "doughnut"
      assert config.data.labels == ["Principal", "Interest"]
      assert [%{data: ["80.00", "20.00"]}] = config.data.datasets
    end

    test "treats missing portions as zero" do
      payments = [%{principal_portion: nil, interest_portion: 500}, %{principal_portion: 100}]
      {nil, config} = build(:interest_breakdown, %{}, [], 10_000, payments)
      assert [%{data: ["1.00", "5.00"]}] = config.data.datasets
    end

    test "a message when nothing's been paid yet" do
      assert {message, nil} = build(:interest_breakdown, %{}, [], 10_000, [])
      assert message =~ "Log a payment"
    end
  end

  describe "budget and convergence errors are never reported as 'add a debt'" do
    for type <- [:comparison, :simulation, :monthly_payments, :freed_cashflow] do
      test "#{type}: insufficient budget" do
        debts = unaffordable()
        strategies = Planning.compare_strategies(debts, 1_000)
        assert {@budget_message, nil} = build(unquote(type), strategies, debts, 1_000)
      end

      test "#{type}: a plan that never pays off" do
        # 50% APR on $10k grows faster than a $1 margin over the minimum.
        debts = [
          debt(
            id: 1,
            type: :revolving,
            balance: 1_000_000,
            apr_bp: 5_000,
            minimum_payment_floor: 100
          )
        ]

        strategies = Planning.compare_strategies(debts, 200)
        assert strategies.cash_flow == {:error, :did_not_converge}

        {message, nil} = build(unquote(type), strategies, debts, 200)
        assert message =~ "doesn't pay off within 50 years"
      end
    end
  end

  describe "build/7 :retirement_roadmap" do
    test "a message when no one has a retirement profile yet" do
      assert {message, nil} = build(:retirement_roadmap, %{}, [], 10_000, [], [])
      assert message =~ "retirement profile"
      assert {^message, nil} = build(:retirement_roadmap, %{}, [], 10_000, [], nil)
    end

    # Ported from the LiveView charts_test, over Engine.Retirement and the
    # snapshot's profile shape (cents / basis points).
    defp profile(attrs) do
      Map.merge(
        %{
          current_age: 30,
          retirement_age: 32,
          current_retirement_savings: 0,
          monthly_retirement_contribution: 0,
          monthly_gross_income: 0,
          post_debt_investment_bp: 1_500,
          expected_annual_return_bp: 700
        },
        Map.new(attrs)
      )
    end

    test "a baseline plus one dataset per strategy when a profile is set" do
      debts = [debt(id: 1, balance: 30_000, fixed_payment: 10_000)]
      profiles = [profile(monthly_retirement_contribution: 10_000, monthly_gross_income: 400_000)]

      {nil, config} = build(:retirement_roadmap, %{}, debts, 10_000, [], profiles)

      assert config.type == "line"
      assert config.data.labels == ["Year 0", "Year 1", "Year 2"]
      assert config.options.interaction == %{mode: "index", intersect: false}

      assert Enum.map(config.data.datasets, & &1.label) ==
               ["Baseline (no debt strategy)", "Cash flow", "Snowball", "Avalanche"]

      for dataset <- config.data.datasets do
        assert length(dataset.data) == 3
        assert Enum.all?(dataset.data, &is_binary/1)
        assert length(dataset.afterLabels) == 3
      end

      # Debt gone by month 3 -> every strategy contributes 15% of $4000.
      cash_flow = Enum.find(config.data.datasets, &(&1.label == "Cash flow"))

      assert cash_flow.afterLabels ==
               ["Contributing $100.00/mo", "Contributing $600.00/mo", "Contributing $600.00/mo"]

      [baseline | _] = config.data.datasets
      assert baseline.afterLabels == List.duplicate("Contributing $100.00/mo", 3)
    end

    test "drops a strategy's dataset when its plan errors, keeping the baseline" do
      {nil, config} = build(:retirement_roadmap, %{}, unaffordable(), 1_000, [], [profile([])])
      assert [%{label: "Baseline (no debt strategy)"}] = config.data.datasets
    end

    test "with no debts, every strategy line matches and diverges from baseline" do
      profiles = [profile(monthly_retirement_contribution: 10_000, monthly_gross_income: 400_000)]
      {nil, config} = build(:retirement_roadmap, %{}, [], 10_000, [], profiles)

      [baseline | strategy_datasets] = config.data.datasets
      strategy_series = Enum.map(strategy_datasets, & &1.data)
      assert Enum.uniq(strategy_series) == [hd(strategy_series)]
      refute hd(strategy_series) == baseline.data
    end

    test "sums two people's projections, each stopping at their own retirement age" do
      common = [
        monthly_retirement_contribution: 10_000,
        post_debt_investment_bp: 0,
        expected_annual_return_bp: 0
      ]

      profiles = [
        profile([retirement_age: 31] ++ common),
        profile([retirement_age: 32] ++ common)
      ]

      {nil, config} = build(:retirement_roadmap, %{}, [], 10_000, [], profiles)

      assert config.data.labels == ["Year 0", "Year 1", "Year 2"]
      [baseline | _] = config.data.datasets
      assert baseline.data == ["0.00", "2400.00", "3600.00"]
    end
  end

  describe "retirement_roadmap_config/2 (chart shape from given projections)" do
    # Mirrors the LiveView test: a 2-year horizon, debt paid off before
    # year 1, contributions jumping from $100 to $600/mo afterwards.
    defp projections do
      baseline = %{
        balances: Enum.map(0..24, &(&1 * 10_000)),
        contributions: List.duplicate(10_000, 24)
      }

      strategy = %{
        balances: Enum.map(0..24, &(&1 * 50_000)),
        contributions: List.duplicate(10_000, 3) ++ List.duplicate(60_000, 21)
      }

      %{
        months: 24,
        baseline: baseline,
        strategies: %{
          cash_flow: {:ok, strategy},
          snowball: {:ok, strategy},
          avalanche: {:ok, strategy}
        }
      }
    end

    test "a baseline plus one dataset per strategy, sampled yearly" do
      config = Charts.retirement_roadmap_config(projections())

      assert config.type == "line"
      assert config.data.labels == ["Year 0", "Year 1", "Year 2"]
      assert config.options.interaction == %{mode: "index", intersect: false}

      assert Enum.map(config.data.datasets, & &1.label) ==
               ["Baseline (no debt strategy)", "Cash flow", "Snowball", "Avalanche"]

      [baseline, cash_flow | _] = config.data.datasets
      assert baseline.data == ["0.00", "1200.00", "2400.00"]
      assert cash_flow.data == ["0.00", "6000.00", "12000.00"]

      assert baseline.afterLabels ==
               List.duplicate("Contributing $100.00/mo", 3)

      assert cash_flow.afterLabels ==
               ["Contributing $100.00/mo", "Contributing $600.00/mo", "Contributing $600.00/mo"]

      for dataset <- config.data.datasets do
        assert length(dataset.data) == 3
        assert length(dataset.afterLabels) == 3
      end
    end

    test "drops an errored strategy, keeping the baseline" do
      projections =
        put_in(projections().strategies, %{
          cash_flow: {:error, :insufficient_budget},
          snowball: {:error, :insufficient_budget},
          avalanche: {:error, :insufficient_budget}
        })

      assert [%{label: "Baseline (no debt strategy)"}] =
               Charts.retirement_roadmap_config(projections).data.datasets
    end

    test "formats contribution lines in the workspace currency" do
      [baseline | _] = Charts.retirement_roadmap_config(projections(), "EUR").data.datasets
      assert hd(baseline.afterLabels) == "Contributing €100.00/mo"
      assert baseline.valueFormat == %{style: "currency", currency: "EUR"}
    end
  end

  describe "formatting is declarative" do
    test "money axes and tooltips carry Intl.NumberFormat options in the workspace currency" do
      debts = two_installments()

      {nil, config} =
        Charts.build(:simulation, :cash_flow, %{}, debts, 20_000, [], [], currency: "GBP")

      assert config.options.locale == "en-US"

      assert config.options.scales.y.ticks.format == %{
               style: "currency",
               currency: "GBP",
               minimumFractionDigits: 0,
               maximumFractionDigits: 0
             }

      assert Enum.all?(
               config.data.datasets,
               &(&1.valueFormat == %{style: "currency", currency: "GBP"})
             )
    end

    test "the comparison chart's months dataset is formatted as months" do
      debts = two_installments()

      {nil, config} =
        build(:comparison, Planning.compare_strategies(debts, 20_000), debts, 20_000)

      assert [%{valueFormat: %{style: "currency"}}, %{valueFormat: %{unit: "month"}}] =
               config.data.datasets
    end

    # The only floats are Chart.js's line `tension` style literals -- never
    # an amount -- so no money ever passes through a float.
    test "configs hold no money floats, atom values or tuples (client-safe, JS-convertible)" do
      debts = two_installments()
      strategies = Planning.compare_strategies(debts, 20_000)
      payments = [%{principal_portion: 100, interest_portion: 5}]

      for type <- Charts.chart_types() -- [:retirement_roadmap] do
        {nil, config} = build(type, strategies, debts, 20_000, payments)
        assert_js_clean(config)
      end

      projections = %{
        months: 12,
        baseline: %{balances: Enum.to_list(0..12), contributions: List.duplicate(1, 12)},
        strategies: %{}
      }

      assert_js_clean(Charts.retirement_roadmap_config(projections))
    end

    defp assert_js_clean(value) when is_map(value) do
      for {key, v} <- value do
        assert is_atom(key)
        if key == :tension, do: assert(is_float(v)), else: assert_js_clean(v)
      end
    end

    defp assert_js_clean(value) when is_list(value), do: Enum.each(value, &assert_js_clean/1)

    defp assert_js_clean(value),
      do: assert(is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value))
  end

  describe "theme_variants/1" do
    test "dark swaps every palette/total/fill literal by value; light is unchanged" do
      debts = two_installments()
      {nil, config} = build(:simulation, %{}, debts, 20_000)

      %{light: light, dark: dark} = Charts.theme_variants(config)
      assert light == config

      assert Enum.map(dark.data.datasets, & &1.borderColor) == ["#e5e7eb", "#60a5fa", "#fb923c"]
      assert Enum.map(dark.data.datasets, & &1.data) == Enum.map(config.data.datasets, & &1.data)
    end

    test "swaps list-valued colors and the freed-cash-flow fill" do
      payments = [%{principal_portion: 100, interest_portion: 5}]
      {nil, doughnut} = build(:interest_breakdown, %{}, [], 0, payments)

      assert [%{backgroundColor: ["#60a5fa", "#fb923c"]}] =
               Charts.themed(doughnut, :dark).data.datasets

      {nil, freed} = build(:freed_cashflow, %{}, two_installments(), 20_000)

      assert [%{backgroundColor: "rgba(96, 165, 250, 0.25)", borderColor: "#60a5fa"}] =
               Charts.themed(freed, :dark).data.datasets
    end
  end

  describe "helpers" do
    test "dollars/1 renders exact cents" do
      assert Charts.dollars(0) == "0.00"
      assert Charts.dollars(5) == "0.05"
      assert Charts.dollars(123_456) == "1234.56"
      assert Charts.dollars(-5) == "-0.05"
      assert Charts.dollars(-100) == "-1.00"
    end

    test "labels every strategy and chart type, and which charts follow the strategy" do
      assert Enum.map(Charts.strategies(), &Charts.strategy_label/1) ==
               ["Cash flow", "Snowball", "Avalanche"]

      assert Enum.map(Charts.chart_types(), &Charts.chart_label/1) == [
               "Compare strategies",
               "Payoff simulation",
               "Monthly payments",
               "Cash flow freed",
               "Interest vs. principal",
               "Retirement roadmap"
             ]

      assert Enum.filter(Charts.chart_types(), &Charts.strategy_dependent?/1) ==
               [:simulation, :monthly_payments, :freed_cashflow]
    end

    test "looks up a debt's name by id, falling back to an empty string" do
      debts = [debt(id: 1, name: "Visa")]
      assert Charts.debt_name(debts, 1) == "Visa"
      assert Charts.debt_name(debts, 999) == ""
    end
  end
end
