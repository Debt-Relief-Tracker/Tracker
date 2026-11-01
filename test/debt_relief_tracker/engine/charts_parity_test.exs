defmodule DebtReliefTracker.Engine.ChartsParityTest do
  # Engine.Charts against the LiveView's Decimal DebtReliefTrackerWeb.Charts,
  # both run live on the engine parity scenarios (test/support/fixtures/
  # engine_scenarios.json). Same chart type, labels, dataset labels, colors
  # and point counts; plotted values agree within the documented drift of
  # under a cent per debt-month (the integer engine posts interest to the
  # cent; docs/architecture/0007-e2ee.md). Messages match except where the
  # LiveView mislabels a budget error as "Add a debt" (freed cash flow).
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Engine.Charts
  alias DebtReliefTracker.Engine.Convert
  alias DebtReliefTracker.Engine.Planning, as: EnginePlanning
  alias DebtReliefTracker.Planning
  alias DebtReliefTrackerWeb.Charts, as: DecimalCharts

  @fixture Path.expand("../../support/fixtures/engine_scenarios.json", __DIR__)
  @scenarios @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

  @atoms %{
    "revolving" => :revolving,
    "installment" => :installment,
    "active" => :active,
    "paid_off" => :paid_off
  }

  defp decimal(nil), do: nil
  defp decimal(value), do: Decimal.new(value)

  defp decimal_debts(rows) do
    Enum.map(rows, fn row ->
      %Debt{
        id: row["id"],
        name: "Debt #{row["id"]}",
        type: Map.fetch!(@atoms, row["type"]),
        status: Map.fetch!(@atoms, row["status"]),
        exclude_from_plan: row["exclude_from_plan"],
        balance: decimal(row["balance"]),
        apr: decimal(row["apr"]),
        fixed_payment: decimal(row["fixed_payment"]),
        minimum_payment_floor: decimal(row["minimum_payment_floor"]),
        minimum_payment_rate: decimal(row["minimum_payment_rate"]),
        credit_limit: decimal(row["credit_limit"])
      }
    end)
  end

  defp engine_debts(decimal_debts),
    do: Enum.map(decimal_debts, &(&1 |> Convert.debt() |> Map.put(:name, &1.name)))

  @payments [
    %{principal: "80.00", interest: "20.00"},
    %{principal: "123.45", interest: "6.78"},
    %{principal: nil, interest: "1.01"}
  ]

  for scenario <- @scenarios, type <- Charts.chart_types() -- [:retirement_roadmap] do
    @scenario scenario
    @type_ type

    test "#{scenario["name"]} / #{type}" do
      d_debts = decimal_debts(@scenario["debts"])
      e_debts = engine_debts(d_debts)
      d_budget = Decimal.new(@scenario["budget"])
      e_budget = Convert.to_cents(@scenario["budget"])

      d_payments =
        Enum.map(
          @payments,
          &%{principal_portion: decimal(&1.principal), interest_portion: decimal(&1.interest)}
        )

      e_payments =
        Enum.map(d_payments, fn p ->
          %{
            principal_portion: Convert.to_cents(p.principal_portion),
            interest_portion: Convert.to_cents(p.interest_portion)
          }
        end)

      for strategy <- Charts.strategies() do
        d_strategies =
          Map.new(Charts.strategies(), &{&1, Planning.simulate(d_debts, d_budget, &1)})

        e_strategies = EnginePlanning.compare_strategies(e_debts, e_budget)

        {d_message, d_config} =
          DecimalCharts.build(@type_, strategy, d_strategies, d_debts, d_budget, d_payments, [])

        {e_message, e_config} =
          Charts.build(@type_, strategy, e_strategies, e_debts, e_budget, e_payments, [])

        assert_same_message(@type_, d_message, e_message)

        horizon =
          e_strategies
          |> Map.values()
          |> Enum.map(&elem(&1, 1))
          |> Enum.map(&((is_map(&1) && &1.total_months) || 1))
          |> Enum.max()

        if d_config,
          do: assert_parity(d_config, e_config, length(Planning.eligible(d_debts)), horizon)
      end
    end
  end

  defp assert_same_message(:freed_cashflow, "Add a debt" <> _, e_message)
       when is_binary(e_message),
       do: assert(e_message =~ "budget" or e_message =~ "Add a debt")

  defp assert_same_message(_type, d_message, e_message), do: assert(d_message == e_message)

  defp assert_parity(d_config, e_config, debt_count, horizon) do
    assert e_config.type == d_config.type
    assert e_config.data.labels == d_config.data.labels
    assert length(e_config.data.datasets) == length(d_config.data.datasets)

    for {d_set, e_set} <- Enum.zip(d_config.data.datasets, e_config.data.datasets) do
      assert Map.get(e_set, :label) == Map.get(d_set, :label)
      assert Map.get(e_set, :backgroundColor) == Map.get(d_set, :backgroundColor)
      assert Map.get(e_set, :borderColor) == Map.get(d_set, :borderColor)
      assert Map.get(e_set, :fill) == Map.get(d_set, :fill)
      assert length(e_set.data) == length(d_set.data)

      e_set.data
      |> Enum.zip(d_set.data)
      |> Enum.with_index(1)
      |> Enum.each(fn {{e_value, d_value}, index} ->
        # A line chart's point `index` is month `index`; the comparison bar
        # holds whole-plan totals, so it gets the whole horizon.
        months = if e_config.type == "bar", do: horizon, else: index
        assert_close(e_value, d_value, months * max(debt_count, 1))
      end)
    end

    # Shared option keys keep their values (the engine only adds locale and
    # declarative formatting).
    for {key, value} <- d_config.options, key != :scales do
      assert Map.fetch!(e_config.options, key) == value
    end

    for {scale, d_scale} <- Map.get(d_config.options, :scales, %{}) do
      assert Map.delete(e_config.options.scales[scale], :ticks) == d_scale
    end
  end

  # Months (comparison) are integers and must match exactly; money is a
  # dollar string vs the LiveView's float, within `max_cents` cents.
  defp assert_close(e_value, d_value, _max_cents) when is_integer(d_value),
    do: assert(e_value == d_value)

  defp assert_close(e_value, d_value, max_cents) when is_binary(e_value) and is_float(d_value) do
    e_cents = Convert.to_cents(e_value)

    d_cents =
      d_value
      |> Decimal.from_float()
      |> Decimal.mult(100)
      |> Decimal.round(0)
      |> Decimal.to_integer()

    assert abs(e_cents - d_cents) <= max_cents,
           "#{e_value} vs #{d_value}: drift over #{max_cents} cents"
  end
end
