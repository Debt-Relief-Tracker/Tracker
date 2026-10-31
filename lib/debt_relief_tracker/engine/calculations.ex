defmodule DebtReliefTracker.Engine.Calculations do
  @moduledoc """
  Client-safe port of `DebtReliefTracker.Debts.Calculations`: per-debt
  interest/minimum-payment math over plain maps in integer cents and basis
  points (see `Engine.Money`). Runs in the browser (Hologram) and in ExUnit.

  Debt maps carry `:type`, `:balance` (cents), `:apr_bp`, and, depending on
  type, `:fixed_payment`, `:minimum_payment_floor` (cents),
  `:minimum_payment_rate_bp`, `:credit_limit`, `:statement_balance` (cents)
  and `:statement_days` (a `Days.to_days/1` count, or `nil`).

  Unlike the Decimal engine, interest is rounded to a whole cent each time
  it is computed, the way a lender posts it.
  """

  alias DebtReliefTracker.Engine.Money

  def minimum_payment(%{type: :installment, fixed_payment: fixed, balance: balance}) do
    fixed |> min(balance) |> Money.clamp_non_negative()
  end

  def minimum_payment(%{type: :revolving, balance: balance} = debt) do
    floor = Map.get(debt, :minimum_payment_floor) || 0
    rate_bp = Map.get(debt, :minimum_payment_rate_bp) || 0

    Money.mul_div(max(balance, 0), rate_bp, 10_000)
    |> max(floor)
    |> min(balance)
    |> Money.clamp_non_negative()
  end

  @doc "One month's interest on `balance` cents at `apr_bp` (simple division by 12)."
  def monthly_interest(balance, apr_bp), do: Money.mul_div(max(balance, 0), apr_bp, 120_000)

  @doc "Interest on `balance` cents over `days` at `apr_bp` (simple daily, /365)."
  def daily_interest(balance, apr_bp, days) when days > 0,
    do: Money.mul_div(max(balance, 0) * days, apr_bp, 3_650_000)

  def daily_interest(_balance, _apr_bp, _days), do: 0

  @doc """
  Estimated interest since the last confirmed statement (revolving debts with
  a statement baseline only; 0 otherwise). `as_of_days` is a `Days.to_days/1`
  count.
  """
  def accrued_interest_estimate(%{type: :installment}, _as_of_days), do: 0
  def accrued_interest_estimate(%{type: :revolving, statement_days: nil}, _as_of_days), do: 0

  def accrued_interest_estimate(%{type: :revolving} = debt, as_of_days) do
    base = Map.get(debt, :statement_balance) || debt.balance
    daily_interest(base, debt.apr_bp, as_of_days - debt.statement_days)
  end

  def estimated_balance(debt, as_of_days),
    do: debt.balance + accrued_interest_estimate(debt, as_of_days)

  def lifetime_interest_paid(payments) do
    Enum.reduce(payments, 0, fn payment, acc ->
      acc + (Map.get(payment, :interest_portion) || 0)
    end)
  end

  def total_remaining_balance(debts, as_of_days) do
    debts
    |> Enum.filter(&(&1.status != :paid_off))
    |> Enum.reduce(0, fn debt, acc -> acc + estimated_balance(debt, as_of_days) end)
  end

  @doc """
  Utilization in basis points (`balance / credit_limit`, 12000 = 120%), or
  `nil` when not applicable (installment, no/zero limit). Not clamped at
  100%; uses the confirmed balance, not the estimate.
  """
  def credit_utilization_bp(%{type: :installment}), do: nil
  def credit_utilization_bp(%{type: :revolving, credit_limit: nil}), do: nil
  def credit_utilization_bp(%{type: :revolving, credit_limit: 0}), do: nil

  def credit_utilization_bp(%{type: :revolving, credit_limit: limit, balance: balance}),
    do: Money.mul_div(Money.clamp_non_negative(balance), 10_000, limit)

  def overall_credit_utilization_bp(debts) do
    eligible = Enum.filter(debts, &(&1.type == :revolving && Map.get(&1, :credit_limit)))
    total_limit = Enum.reduce(eligible, 0, &(&1.credit_limit + &2))

    if eligible == [] or total_limit == 0 do
      nil
    else
      total_balance = Enum.reduce(eligible, 0, &(&1.balance + &2))
      Money.mul_div(Money.clamp_non_negative(total_balance), 10_000, total_limit)
    end
  end
end
