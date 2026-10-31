defmodule DebtReliefTracker.Engine.CalculationsTest do
  use ExUnit.Case, async: true

  alias DebtReliefTracker.Engine.Calculations
  alias DebtReliefTracker.Engine.Days

  @card %{
    type: :revolving,
    status: :active,
    balance: 100_000,
    apr_bp: 2400,
    minimum_payment_floor: 2500,
    minimum_payment_rate_bp: 200,
    credit_limit: 200_000,
    statement_balance: 100_000,
    statement_days: Days.to_days({2026, 10, 1})
  }

  test "revolving minimum is max(floor, rate * balance), capped at the balance" do
    assert Calculations.minimum_payment(@card) == 2000 |> max(2500)
    assert Calculations.minimum_payment(%{@card | balance: 3000}) == 2500 |> min(3000)
    assert Calculations.minimum_payment(%{@card | balance: 1000}) == 1000
    assert Calculations.minimum_payment(%{@card | balance: 0}) == 0
  end

  test "installment minimum is the fixed payment capped at the balance" do
    loan = %{type: :installment, fixed_payment: 31_000, balance: 1_200_000}
    assert Calculations.minimum_payment(loan) == 31_000
    assert Calculations.minimum_payment(%{loan | balance: 10_000}) == 10_000
  end

  test "monthly interest: 24% APR on $1,000 is $20.00" do
    assert Calculations.monthly_interest(100_000, 2400) == 2000
  end

  test "accrued estimate uses simple daily interest on the statement balance" do
    as_of = Days.to_days({2026, 10, 31})
    # 100000 cents * 30 days * 24% / 365 = 1972.6 cents
    assert Calculations.accrued_interest_estimate(@card, as_of) == 1973
    assert Calculations.estimated_balance(@card, as_of) == 101_973
    assert Calculations.accrued_interest_estimate(@card, Days.to_days({2026, 10, 1})) == 0
    assert Calculations.accrued_interest_estimate(%{@card | statement_days: nil}, as_of) == 0
    assert Calculations.accrued_interest_estimate(%{type: :installment}, as_of) == 0
  end

  test "utilization is in basis points, unclamped, and nil when not applicable" do
    assert Calculations.credit_utilization_bp(@card) == 5000
    assert Calculations.credit_utilization_bp(%{@card | balance: 240_000}) == 12_000
    assert Calculations.credit_utilization_bp(%{@card | credit_limit: nil}) == nil
    assert Calculations.credit_utilization_bp(%{@card | credit_limit: 0}) == nil
    assert Calculations.credit_utilization_bp(%{type: :installment}) == nil
    assert Calculations.overall_credit_utilization_bp([@card, @card]) == 5000
    assert Calculations.overall_credit_utilization_bp([%{type: :installment}]) == nil
  end
end
