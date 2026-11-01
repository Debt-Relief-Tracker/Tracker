defmodule DebtReliefTracker.BrowserCase.EngineDigest do
  @moduledoc """
  Test-only. Runs the real `DebtReliefTracker.Engine.*` modules on one
  scenario and flattens every result into `key => text` pairs of integers
  and strings. It is plain, client-safe Elixir, so the very same function
  runs on the server (ExUnit) and in the browser (`EngineParityPage`); the
  browser test asserts the two maps are identical.

  Text format: `name=value;` tokens, lists comma separated, so the test can
  also parse numbers back out to check the Decimal-reference tolerances.
  """

  alias DebtReliefTracker.Engine.Calculations
  alias DebtReliefTracker.Engine.Charts
  alias DebtReliefTracker.Engine.Days
  alias DebtReliefTracker.Engine.Planning
  alias DebtReliefTracker.Engine.Retirement

  @strategies [:cash_flow, :snowball, :avalanche]
  @chart_types [:comparison, :simulation, :monthly_payments, :freed_cashflow, :interest_breakdown]
  # A fixed "today" (2026-11-01) so estimates do not depend on the clock.
  @as_of {2026, 11, 1}
  @payments [
    %{principal_portion: 8000, interest_portion: 2000},
    %{principal_portion: 12_345, interest_portion: 678},
    %{principal_portion: nil, interest_portion: 101}
  ]

  def strategies, do: @strategies

  @doc "Debt-level maths and, per strategy, planning + every chart type, for one scenario."
  def scenario(%{debts: debts, budget: budget, lump: lump}) do
    as_of = Days.to_days(@as_of)

    calc = %{
      "calc" =>
        join_tokens([
          {"min", ints(Enum.map(debts, &Calculations.minimum_payment/1))},
          {"interest",
           ints(Enum.map(debts, &Calculations.monthly_interest(&1.balance, &1.apr_bp)))},
          {"daily31",
           ints(Enum.map(debts, &Calculations.daily_interest(&1.balance, &1.apr_bp, 31)))},
          {"accrued", ints(Enum.map(debts, &Calculations.accrued_interest_estimate(&1, as_of)))},
          {"estimated", ints(Enum.map(debts, &Calculations.estimated_balance(&1, as_of)))},
          {"util", ints(Enum.map(debts, &nil_to_neg(Calculations.credit_utilization_bp(&1))))},
          {"overall_util", nil_to_neg(Calculations.overall_credit_utilization_bp(debts))},
          {"remaining", Calculations.total_remaining_balance(debts, as_of)},
          {"lifetime_interest", Calculations.lifetime_interest_paid(@payments)}
        ])
    }

    strategies = Planning.compare_strategies(debts, budget)

    per_strategy =
      Enum.reduce(@strategies, %{}, fn strategy, acc ->
        result = Map.fetch!(strategies, strategy)
        ordered = strategy |> Planning.order(Planning.eligible(debts)) |> Enum.map(& &1.id)

        windfall =
          case Planning.windfall_cascade(debts, budget, strategy, lump) do
            {:ok, %{months_saved: m, interest_saved: i}} ->
              "ok;saved_months=#{m};saved_interest=#{i}"

            {:error, reason} ->
              "error:#{reason}"
          end

        text =
          join_tokens([
            {"min_total", Planning.total_minimum_payments(debts)},
            {"order", Enum.join(ordered, ",")},
            {"windfall", windfall},
            {"sim", sim(result)},
            {"freed", freed(debts, result)}
          ])

        Map.put(acc, "plan-#{strategy}", text)
      end)

    # Comparison and interest/principal ignore the selected strategy, so one
    # strategy covers them; the rest are built for all three.
    charts =
      for chart_type <- @chart_types,
          strategy <- chart_strategies(chart_type),
          into: %{} do
        {message, config} =
          Charts.build(chart_type, strategy, strategies, debts, budget, @payments, [])

        {"chart-#{chart_type}-#{strategy}", chart(message, config)}
      end

    calc |> Map.merge(per_strategy) |> Map.merge(charts)
  end

  @doc "Retirement baseline series for one profile set."
  def retirement_base(profiles) do
    %{
      "ret-base" =>
        join_tokens([
          {"months", Retirement.combined_months_to_retirement(profiles)},
          {"balances", ints(Retirement.baseline_projection(profiles))},
          {"contributions", ints(Retirement.baseline_contributions(profiles))}
        ])
    }
  end

  @doc "Strategy projections and the roadmap chart for one profile set x debt case."
  def retirement_case(profiles, %{key: key, debts: debts, budget: budget}) do
    by_strategy =
      Enum.reduce(@strategies, %{}, fn strategy, acc ->
        text =
          case Retirement.strategy_projection_with_contributions(
                 debts,
                 profiles,
                 budget,
                 strategy
               ) do
            {:ok, %{balances: b, contributions: c}} ->
              join_tokens([{"status", "ok"}, {"balances", ints(b)}, {"contributions", ints(c)}])

            {:error, reason} ->
              join_tokens([{"status", "error"}, {"reason", Atom.to_string(reason)}])
          end

        Map.put(acc, "ret-#{key}-#{strategy}", text)
      end)

    projections = Charts.retirement_projections(profiles, debts, budget)
    config = Charts.retirement_roadmap_config(projections)
    Map.put(by_strategy, "ret-#{key}-roadmap", chart(nil, config))
  end

  defp chart_strategies(chart_type) do
    if Charts.strategy_dependent?(chart_type), do: @strategies, else: [:cash_flow]
  end

  # --- serializers ---------------------------------------------------------

  defp sim({:error, reason}), do: "error:#{reason}"

  defp sim({:ok, %{months: months, total_months: total, total_interest: interest}}) do
    first = months |> Enum.take(1) |> Enum.map(&Map.get(&1, :target_debt_id)) |> Enum.join(",")

    lines =
      Enum.map_join(months, "|", fn month ->
        month_text =
          Enum.map_join(month.lines, "/", fn line ->
            ints([
              line.starting_balance,
              line.interest_accrued,
              line.minimum_payment,
              line.payment,
              line.ending_balance
            ])
          end)

        "#{month.index}:#{month.target_debt_id}:#{month_text}"
      end)

    "ok;months=#{total};interest=#{interest};first_target=#{first};lines=#{lines}"
  end

  defp freed(debts, {:ok, %{months: months}}) when months != [] do
    ints(Enum.map(Planning.freed_cashflow_from_months(debts, months), & &1.freed))
  end

  defp freed(_debts, _result), do: "n/a"

  defp chart(message, nil), do: "message=#{message}"

  defp chart(_message, config) do
    sets =
      Enum.map_join(config.data.datasets, "|", fn set ->
        "#{Map.get(set, :label)}=#{Enum.map_join(set.data, ",", &scalar/1)}"
      end)

    "type=#{config.type};labels=#{Enum.join(config.data.labels, ",")};sets=#{sets}"
  end

  defp scalar(nil), do: "nil"
  defp scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar(value) when is_binary(value), do: value
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)

  defp scalar(%{} = value) do
    value
    |> Map.to_list()
    |> Enum.sort()
    |> Enum.map_join(";", fn {key, v} -> "#{key}:#{scalar(v)}" end)
  end

  defp ints(list), do: Enum.map_join(list, ",", fn n -> Integer.to_string(n) end)
  defp nil_to_neg(nil), do: -1
  defp nil_to_neg(n), do: n

  defp join_tokens(pairs),
    do: Enum.map_join(pairs, ";", fn {name, value} -> "#{name}=#{value}" end)
end
