defmodule DebtReliefTracker.Debts.Calculations do
  @moduledoc """
  Pure interest/minimum-payment math for a single debt (docs/plan.md Phase
  4). No Ecto, no I/O -- takes plain structs/maps with the relevant fields
  and returns `Decimal`s, so it's cheap to unit test and reusable by both the
  live dashboard and the `Planning` simulation engine.
  """

  @doc """
  The dynamic minimum payment for a debt this month:

    * revolving: `max(floor, rate * balance)`, capped at the balance itself
      (never ask for more than is owed).
    * installment: the fixed payment, capped at the balance (the final
      payment is often smaller than the regular one).

  Accepts anything with the right keys -- a real `%Debt{}` or a plain map,
  which is what `Planning`'s month-by-month simulation uses.
  """
  def minimum_payment(%{type: :installment, fixed_payment: fixed_payment, balance: balance}) do
    fixed_payment
    |> to_decimal()
    |> Decimal.min(to_decimal(balance))
    |> clamp_non_negative()
  end

  def minimum_payment(%{
        type: :revolving,
        balance: balance,
        minimum_payment_floor: floor,
        minimum_payment_rate: rate
      }) do
    balance = to_decimal(balance)
    floor = to_decimal(floor || 0)
    rate = to_decimal(rate || 0)

    Decimal.mult(balance, rate)
    |> Decimal.max(floor)
    |> Decimal.min(balance)
    |> clamp_non_negative()
  end

  @doc "Monthly periodic rate implied by an APR (simple division by 12)."
  def monthly_rate(apr), do: apr |> to_decimal() |> Decimal.div(100) |> Decimal.div(12)

  @doc "Daily periodic rate implied by an APR (simple division by 365)."
  def daily_rate(apr), do: apr |> to_decimal() |> Decimal.div(100) |> Decimal.div(365)

  @doc """
  Estimated interest accrued on a revolving debt since its last confirmed
  statement, using simple daily interest on the statement balance. Zero for
  installment debts (they follow a fixed schedule, no estimate) and for any
  debt with no statement baseline yet.
  """
  def accrued_interest_estimate(debt, as_of \\ Date.utc_today())

  def accrued_interest_estimate(%{type: :installment}, _as_of), do: Decimal.new(0)

  def accrued_interest_estimate(%{type: :revolving, statement_date: nil}, _as_of),
    do: Decimal.new(0)

  def accrued_interest_estimate(%{type: :revolving} = debt, as_of) do
    days = Date.diff(as_of, debt.statement_date)

    if days <= 0 do
      Decimal.new(0)
    else
      base = to_decimal(debt.statement_balance || debt.balance)

      base
      |> Decimal.mult(daily_rate(debt.apr))
      |> Decimal.mult(Decimal.new(days))
    end
  end

  @doc """
  The debt's balance including the estimated interest overlay (marked
  `est.` in the UI) -- equal to the confirmed balance for installment debts.
  """
  def estimated_balance(debt, as_of \\ Date.utc_today()) do
    Decimal.add(to_decimal(debt.balance), accrued_interest_estimate(debt, as_of))
  end

  @doc "Sums the interest_portion of a list of payments (lifetime interest paid)."
  def lifetime_interest_paid(payments) do
    Enum.reduce(payments, Decimal.new(0), fn payment, acc ->
      Decimal.add(acc, to_decimal(payment.interest_portion || 0))
    end)
  end

  @doc "Sum of estimated balances across all non-paid-off debts (a \"how much do I owe\" total)."
  def total_remaining_balance(debts) do
    debts
    |> Enum.filter(&(&1.status != :paid_off))
    |> Enum.map(&estimated_balance/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  @doc false
  def to_decimal(%Decimal{} = d), do: d
  def to_decimal(n) when is_integer(n), do: Decimal.new(n)
  def to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  def to_decimal(n) when is_binary(n), do: Decimal.new(n)

  defp clamp_non_negative(%Decimal{} = d) do
    if Decimal.negative?(d), do: Decimal.new(0), else: d
  end
end
