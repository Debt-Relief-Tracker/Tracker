# Regenerates retirement_scenarios.json from the Decimal retirement projection
# (DebtReliefTracker.Planning.Retirement), the reference the integer engine
# (Engine.Retirement) must match. Pure -- no app start, no DB. Debt scenarios
# are reused from engine_scenarios.json (run generate_engine_scenarios.exs
# first if that changes):
#
#     MIX_ENV=test mix run --no-start test/support/fixtures/generate_retirement_scenarios.exs
#
# Inputs are decimal strings (what the schema stores); expected outputs are
# lists of decimal strings.
alias DebtReliefTracker.Planning.Retirement

d = &Decimal.new/1
str = &Decimal.to_string(&1, :normal)

debts_path = Path.join(__DIR__, "engine_scenarios.json")
debt_scenarios = debts_path |> File.read!() |> Jason.decode!() |> Map.fetch!("scenarios")

profile = fn age, retire, savings, contribution, income, pct, ret ->
  %{
    "current_age" => age,
    "retirement_age" => retire,
    "current_retirement_savings" => savings,
    "monthly_retirement_contribution" => contribution,
    "monthly_gross_income" => income,
    "post_debt_investment_pct" => pct,
    "expected_annual_return_pct" => ret
  }
end

profile_sets = [
  %{name: "single_standard", profiles: [profile.(30, 65, "10000", "200", "5000", "15", "7")]},
  %{
    name: "couple_different_horizons",
    profiles: [
      profile.(35, 67, "45000.50", "650", "6200", "12", "6.5"),
      profile.(28, 60, "8000", "150", "3800", "20", "8")
    ]
  },
  %{name: "near_retirement", profiles: [profile.(60, 65, "250000", "0", "7000", "25", "5")]},
  %{name: "zero_return", profiles: [profile.(25, 70, "1000", "100", "3000", "10", "0")]},
  %{
    name: "fractional_inputs",
    profiles: [
      profile.(41, 66, "12345.67", "333.33", "4321.57", "12.5", "7.25"),
      profile.(39, 62, "0", "0", "2999.99", "17.5", "9.5")
    ]
  }
]

atoms = %{
  "revolving" => :revolving,
  "installment" => :installment,
  "active" => :active,
  "paid_off" => :paid_off
}

to_ref = fn row ->
  %{
    id: row["id"],
    type: Map.fetch!(atoms, row["type"]),
    status: Map.fetch!(atoms, row["status"]),
    exclude_from_plan: row["exclude_from_plan"],
    balance: d.(row["balance"]),
    apr: d.(row["apr"]),
    minimum_payment_floor: row["minimum_payment_floor"] && d.(row["minimum_payment_floor"]),
    minimum_payment_rate: row["minimum_payment_rate"] && d.(row["minimum_payment_rate"]),
    fixed_payment: row["fixed_payment"] && d.(row["fixed_payment"]),
    credit_limit: row["credit_limit"] && d.(row["credit_limit"])
  }
end

to_ref_profile = fn row ->
  Map.new(row, fn
    {k, v} when is_integer(v) -> {String.to_atom(k), v}
    {k, v} -> {String.to_atom(k), d.(v)}
  end)
end

strategies = [:cash_flow, :snowball, :avalanche]

scenarios =
  for set <- profile_sets do
    profiles = Enum.map(set.profiles, to_ref_profile)

    debt_cases =
      for s <- debt_scenarios do
        debts = Enum.map(s["debts"], to_ref)
        budget = d.(s["budget"])

        by_strategy =
          for strategy <- strategies, into: %{} do
            result =
              case Retirement.strategy_projection_with_contributions(
                     debts,
                     profiles,
                     budget,
                     strategy
                   ) do
                {:ok, %{balances: b, contributions: c}} ->
                  %{status: "ok", balances: Enum.map(b, str), contributions: Enum.map(c, str)}

                {:error, reason} ->
                  %{status: "error", reason: to_string(reason)}
              end

            {to_string(strategy), result}
          end

        %{debt_scenario: s["name"], strategies: by_strategy}
      end

    %{
      name: set.name,
      profiles: set.profiles,
      months: Retirement.combined_months_to_retirement(profiles),
      baseline: %{
        balances: profiles |> Retirement.baseline_projection() |> Enum.map(str),
        contributions: profiles |> Retirement.baseline_contributions() |> Enum.map(str)
      },
      debt_cases: debt_cases
    }
  end

path = Path.join(__DIR__, "retirement_scenarios.json")
File.write!(path, Jason.encode!(%{scenarios: scenarios}))
IO.puts("wrote #{path} (#{length(scenarios)} profile sets)")
