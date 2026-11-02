# Regenerates engine_scenarios.json from the Decimal engine
# (DebtReliefTracker.Debts.Calculations / Planning), which is the reference the
# integer-cents engine (Engine.*) must match. Pure -- no app start, no DB:
#
#     MIX_ENV=test mix run --no-start test/support/fixtures/generate_engine_scenarios.exs
#
# Inputs are decimal strings (what the schema stores); expected outputs are
# decimal strings of the reference result.
alias DebtReliefTracker.Debts.Calculations
alias DebtReliefTracker.Planning

d = &Decimal.new/1

debt = fn id, attrs ->
  Map.merge(
    %{
      "id" => id,
      "type" => "revolving",
      "balance" => "0",
      "apr" => "0",
      "minimum_payment_floor" => nil,
      "minimum_payment_rate" => nil,
      "fixed_payment" => nil,
      "credit_limit" => nil,
      "exclude_from_plan" => false,
      "status" => "active"
    },
    attrs
  )
end

to_ref = fn row ->
  %{
    id: row["id"],
    type: String.to_existing_atom(row["type"]),
    status: String.to_existing_atom(row["status"]),
    exclude_from_plan: row["exclude_from_plan"],
    balance: d.(row["balance"]),
    apr: d.(row["apr"]),
    minimum_payment_floor: row["minimum_payment_floor"] && d.(row["minimum_payment_floor"]),
    minimum_payment_rate: row["minimum_payment_rate"] && d.(row["minimum_payment_rate"]),
    fixed_payment: row["fixed_payment"] && d.(row["fixed_payment"]),
    credit_limit: row["credit_limit"] && d.(row["credit_limit"])
  }
end

card = fn id, balance, apr, limit ->
  debt.(id, %{
    "balance" => balance,
    "apr" => apr,
    "minimum_payment_floor" => "25",
    "minimum_payment_rate" => "0.02",
    "credit_limit" => limit
  })
end

loan = fn id, balance, apr, payment ->
  debt.(id, %{
    "type" => "installment",
    "balance" => balance,
    "apr" => apr,
    "fixed_payment" => payment
  })
end

scenarios = [
  %{
    name: "mixed_four_debts",
    budget: "1500",
    lump_sum: "2000",
    debts: [
      card.("card-a", "4200.00", "24.99", "5000"),
      card.("card-b", "1800.50", "19.49", "3000"),
      card.("card-c", "950.75", "29.99", "1500"),
      loan.("loan-d", "12000.00", "6.5", "310")
    ]
  },
  %{
    name: "single_card",
    budget: "400",
    lump_sum: "500",
    debts: [card.("only", "3000.00", "21.99", "6000")]
  },
  %{
    name: "tight_budget",
    budget: "260",
    lump_sum: "300",
    debts: [
      card.("t-1", "5000.00", "26.99", "5500"),
      loan.("t-2", "2500.00", "11.0", "120")
    ]
  },
  %{
    name: "excluded_and_paid_off",
    budget: "900",
    lump_sum: "1000",
    debts: [
      card.("e-1", "2200.00", "22.0", "4000"),
      debt.("e-2", %{
        "type" => "installment",
        "balance" => "30000",
        "apr" => "3.0",
        "fixed_payment" => "450",
        "exclude_from_plan" => true
      }),
      debt.("e-3", %{
        "type" => "installment",
        "balance" => "0",
        "apr" => "5",
        "fixed_payment" => "100",
        "status" => "paid_off"
      })
    ]
  },
  %{
    name: "insufficient_budget",
    budget: "50",
    lump_sum: "0",
    debts: [card.("i-1", "8000.00", "27.99", "8000"), loan.("i-2", "4000", "9.0", "200")]
  }
]

str = fn
  %Decimal{} = v -> Decimal.to_string(v, :normal)
  nil -> nil
  v -> to_string(v)
end

result = fn
  {:ok, %{months: months, total_months: n, total_interest: interest}} ->
    first = List.first(months)

    %{
      status: "ok",
      total_months: n,
      total_interest: str.(interest),
      first_month:
        first &&
          %{
            target_debt_id: first.target_debt_id,
            payments: Enum.map(first.lines, &%{debt_id: &1.debt_id, payment: str.(&1.payment)})
          }
    }

  {:error, reason} ->
    %{status: "error", reason: to_string(reason)}
end

expected =
  for s <- scenarios do
    debts = Enum.map(s.debts, to_ref)
    budget = d.(s.budget)

    strategies =
      for strategy <- [:cash_flow, :snowball, :avalanche], into: %{} do
        windfall =
          case Planning.windfall_cascade(debts, budget, strategy, d.(s.lump_sum)) do
            {:ok, w} -> %{interest_saved: str.(w.interest_saved), months_saved: w.months_saved}
            {:error, reason} -> %{error: to_string(reason)}
          end

        order =
          debts |> Planning.eligible() |> then(&Planning.order(strategy, &1)) |> Enum.map(& &1.id)

        {to_string(strategy),
         %{
           order: order,
           simulation: result.(Planning.simulate(debts, budget, strategy)),
           windfall: windfall
         }}
      end

    revolving = Enum.filter(debts, &(&1.type == :revolving))

    %{
      name: s.name,
      budget: s.budget,
      lump_sum: s.lump_sum,
      debts: s.debts,
      expected: %{
        total_minimum_payments: str.(Planning.total_minimum_payments(debts)),
        minimum_payments: Map.new(debts, &{&1.id, str.(Calculations.minimum_payment(&1))}),
        overall_utilization: str.(Calculations.overall_credit_utilization(revolving)),
        strategies: strategies
      }
    }
  end

path = Path.join(__DIR__, "engine_scenarios.json")
File.write!(path, Jason.encode!(%{scenarios: expected}, pretty: true))
IO.puts("wrote #{path} (#{length(expected)} scenarios)")
