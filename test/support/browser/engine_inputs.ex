defmodule DebtReliefTracker.BrowserCase.EngineInputs do
  @moduledoc """
  Test-only, server-side: turns the Decimal engine fixtures
  (`engine_scenarios.json`, `retirement_scenarios.json`) into the integer
  inputs `EngineDigest` takes, via `Engine.Convert`.
  """

  alias DebtReliefTracker.Engine.Convert
  alias DebtReliefTracker.Engine.Days

  @fixtures Path.expand("../fixtures", __DIR__)

  @atoms %{
    "revolving" => :revolving,
    "installment" => :installment,
    "active" => :active,
    "paid_off" => :paid_off
  }

  @doc "Raw decoded fixtures: `{engine_scenarios, retirement_sets}`."
  def raw do
    {read("engine_scenarios.json")["scenarios"], read("retirement_scenarios.json")["scenarios"]}
  end

  def load do
    {scenarios, sets} = raw()

    scenarios_in =
      scenarios |> Enum.with_index() |> Enum.map(fn {s, i} -> scenario_input(s, i) end)

    sets_in =
      sets
      |> Enum.with_index()
      |> Enum.map(fn {set, i} ->
        %{
          index: i,
          name: set["name"],
          profiles: Enum.map(set["profiles"], &profile/1),
          cases:
            Enum.map(set["debt_cases"], fn c ->
              sc = Enum.find(scenarios_in, &(&1.name == c["debt_scenario"]))
              %{key: c["debt_scenario"], debts: sc.debts, budget: sc.budget}
            end)
        }
      end)

    # One browser click each: a set's baseline, then each of its debt cases.
    jobs =
      sets_in
      |> Enum.flat_map(fn set ->
        [%{set: set.index, profiles: set.profiles, case: nil}] ++
          Enum.map(set.cases, &%{set: set.index, profiles: set.profiles, case: &1})
      end)
      |> Enum.with_index()
      |> Enum.map(fn {job, id} -> Map.put(job, :id, id) end)

    %{scenarios: scenarios_in, sets: sets_in, jobs: jobs}
  end

  defp scenario_input(s, index) do
    %{
      index: index,
      name: s["name"],
      budget: Convert.to_cents(s["budget"]),
      lump: Convert.to_cents(s["lump_sum"]),
      debts: Enum.map(s["debts"], &debt/1)
    }
  end

  # The engine debt map, plus a name (chart labels) and a statement baseline
  # on revolving debts so the accrued-interest estimate is exercised too.
  defp debt(row) do
    converted =
      Convert.debt(%{
        id: row["id"],
        type: Map.fetch!(@atoms, row["type"]),
        status: Map.fetch!(@atoms, row["status"]),
        exclude_from_plan: row["exclude_from_plan"],
        balance: row["balance"],
        apr: row["apr"],
        fixed_payment: row["fixed_payment"],
        minimum_payment_floor: row["minimum_payment_floor"],
        minimum_payment_rate: row["minimum_payment_rate"],
        credit_limit: row["credit_limit"]
      })

    converted = Map.put(converted, :name, "Debt " <> row["id"])

    if converted.type == :revolving do
      %{
        converted
        | statement_balance: max(converted.balance - 12_345, 0),
          statement_days: Days.to_days({2026, 10, 1})
      }
    else
      converted
    end
  end

  defp profile(row) do
    %{
      current_age: row["current_age"],
      retirement_age: row["retirement_age"],
      current_retirement_savings: Convert.to_cents(row["current_retirement_savings"]),
      monthly_retirement_contribution: Convert.to_cents(row["monthly_retirement_contribution"]),
      monthly_gross_income: Convert.to_cents(row["monthly_gross_income"]),
      post_debt_investment_bp: Convert.percent_to_bp(row["post_debt_investment_pct"]),
      expected_annual_return_bp: Convert.percent_to_bp(row["expected_annual_return_pct"])
    }
  end

  defp read(file), do: @fixtures |> Path.join(file) |> File.read!() |> Jason.decode!()
end
