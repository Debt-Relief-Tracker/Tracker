defmodule DebtReliefTracker.Planning do
  @moduledoc """
  Payoff strategy comparison and month-by-month simulation (docs/plan.md
  Phase 4). Pure functions over lists of debt-like structs/maps -- no Ecto,
  no I/O. `Debts.Calculations` supplies the per-debt minimum-payment math
  this builds on.

  A strategy only decides the *order* debts are targeted in; every strategy
  pays every eligible debt's minimum payment every month and funnels
  whatever budget is left over, in order, into the current target debt
  (cascading into the next one the same month if the target gets paid off
  with room to spare). The order itself is computed once, up front, from the
  debts' starting balances -- it does not get recomputed mid-simulation.
  """

  alias DebtReliefTracker.Debts.Calculations

  @max_months 600

  @doc """
  Debts eligible for the consumer payoff plan: active, non-zero balance, and
  not flagged `exclude_from_plan` (docs/plan.md: "Low-rate installment loans
  can be flagged excludeFromPlan to keep them out of the consumer payoff
  plan while still counting in your totals").
  """
  def eligible(debts) do
    Enum.filter(debts, fn debt ->
      debt.status != :paid_off and not debt.exclude_from_plan and
        Decimal.positive?(Calculations.to_decimal(debt.balance))
    end)
  end

  @doc "Sum of minimum payments across all plan-eligible debts this month."
  def total_minimum_payments(debts) do
    debts
    |> eligible()
    |> Enum.map(&Calculations.minimum_payment/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  @doc """
  Orders debts for a strategy:

    * `:cash_flow` -- highest ratio of minimum payment to balance first
      (paying it off frees the most monthly payment per dollar spent).
    * `:snowball` -- smallest balance first.
    * `:avalanche` -- highest APR first (least total interest).
  """
  def order(:cash_flow, debts) do
    Enum.sort_by(debts, &cash_flow_ratio/1, :desc)
  end

  def order(:snowball, debts) do
    Enum.sort_by(debts, &Decimal.to_float(Calculations.to_decimal(&1.balance)), :asc)
  end

  def order(:avalanche, debts) do
    Enum.sort_by(debts, &Decimal.to_float(Calculations.to_decimal(&1.apr)), :desc)
  end

  defp cash_flow_ratio(debt) do
    balance = Calculations.to_decimal(debt.balance)

    if Decimal.eq?(balance, 0) do
      0.0
    else
      Calculations.minimum_payment(debt)
      |> Decimal.div(balance)
      |> Decimal.to_float()
    end
  end

  @doc """
  Simulates a strategy month by month at `monthly_budget` until every
  eligible debt is paid off (or `#{@max_months}` months pass without
  converging, or some month's budget doesn't cover that month's minimum
  payments -- checked against the actual interest-accrued balances for that
  month, not a pre-interest estimate, so a budget that's razor-thin against
  month one's true minimums is correctly rejected rather than silently
  underpaid).

  Returns `{:ok, %{months: [...], total_months: n, total_interest: Decimal}}`
  or `{:error, :insufficient_budget | :did_not_converge}`.
  """
  def simulate(debts, monthly_budget, strategy, opts \\ []) do
    ordered = order(strategy, eligible(debts))
    budget = Calculations.to_decimal(monthly_budget)
    extra_first_month = Calculations.to_decimal(Keyword.get(opts, :extra_first_month, 0))

    if ordered == [] do
      {:ok, %{months: [], total_months: 0, total_interest: Decimal.new(0)}}
    else
      do_simulate(ordered, budget, extra_first_month, [], Decimal.new(0), 1)
    end
  end

  defp do_simulate(_debts, _budget, _extra, _months_acc, _total_interest, month)
       when month > @max_months do
    {:error, :did_not_converge}
  end

  defp do_simulate(debts, budget, extra_first_month, months_acc, total_interest, month) do
    if Enum.all?(debts, &Decimal.eq?(Calculations.to_decimal(&1.balance), 0)) do
      {:ok,
       %{
         months: Enum.reverse(months_acc),
         total_months: month - 1,
         total_interest: total_interest
       }}
    else
      extra_this_month =
        if month == 1, do: Calculations.to_decimal(extra_first_month), else: Decimal.new(0)

      case run_month(debts, budget, extra_this_month, month) do
        {:ok, updated, snapshot, month_interest} ->
          do_simulate(
            updated,
            budget,
            extra_first_month,
            [snapshot | months_acc],
            Decimal.add(total_interest, month_interest),
            month + 1
          )

        :insufficient_budget ->
          {:error, :insufficient_budget}
      end
    end
  end

  # Runs one month: accrue interest, pay minimums, then cascade whatever
  # budget is left (plus any one-off extra, e.g. a windfall) down the fixed
  # order, moving to the next debt the instant one is paid off.
  defp run_month(debts, budget, extra_this_month, month_index) do
    accrued =
      Enum.map(debts, fn debt ->
        interest =
          if Decimal.eq?(Calculations.to_decimal(debt.balance), 0) do
            Decimal.new(0)
          else
            Decimal.mult(
              Calculations.to_decimal(debt.balance),
              Calculations.monthly_rate(debt.apr)
            )
          end

        %{
          debt: %{debt | balance: Decimal.add(Calculations.to_decimal(debt.balance), interest)},
          interest: interest
        }
      end)

    minimums = Enum.map(accrued, fn %{debt: debt} -> Calculations.minimum_payment(debt) end)
    minimums_total = Enum.reduce(minimums, Decimal.new(0), &Decimal.add/2)
    available = Decimal.add(budget, extra_this_month)

    if Decimal.compare(available, minimums_total) == :lt do
      :insufficient_budget
    else
      cascade_pool = Decimal.sub(available, minimums_total)
      {payments, target_debt_id} = allocate(accrued, minimums, cascade_pool)

      updated_debts =
        Enum.zip(accrued, payments)
        |> Enum.map(fn {%{debt: debt}, payment} ->
          %{debt | balance: Decimal.sub(debt.balance, payment) |> Decimal.max(0)}
        end)

      month_interest =
        accrued |> Enum.map(& &1.interest) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      snapshot = %{
        index: month_index,
        target_debt_id: target_debt_id,
        lines:
          Enum.zip([accrued, minimums, payments])
          |> Enum.map(fn {%{debt: debt, interest: interest}, minimum, payment} ->
            %{
              debt_id: debt.id,
              starting_balance: debt.balance,
              interest_accrued: interest,
              minimum_payment: minimum,
              payment: payment,
              ending_balance: Decimal.sub(debt.balance, payment) |> Decimal.max(0)
            }
          end)
      }

      {:ok, updated_debts, snapshot, month_interest}
    end
  end

  # Pays each debt its minimum, then walks the (already-ordered) list once
  # more pouring the cascade pool into the first debt with room for it,
  # overflowing into the next when a debt is paid off with money to spare.
  defp allocate(accrued, minimums, cascade_pool) do
    debts = Enum.map(accrued, & &1.debt)

    {payments, _remaining, target_debt_id} =
      Enum.zip(debts, minimums)
      |> Enum.reduce({[], cascade_pool, nil}, fn {debt, minimum}, {payments, pool, target} ->
        room = Decimal.sub(debt.balance, minimum) |> Decimal.max(0)
        applied = Decimal.min(pool, room)
        target = target || if Decimal.positive?(pool) and Decimal.positive?(room), do: debt.id
        payment = Decimal.add(minimum, applied)
        {[payment | payments], Decimal.sub(pool, applied), target}
      end)

    {Enum.reverse(payments), target_debt_id}
  end

  @doc "Runs all three strategies at the same budget for a side-by-side comparison."
  def compare_strategies(debts, monthly_budget) do
    %{
      cash_flow: simulate(debts, monthly_budget, :cash_flow),
      snowball: simulate(debts, monthly_budget, :snowball),
      avalanche: simulate(debts, monthly_budget, :avalanche)
    }
  end

  @doc """
  What to pay, and to which debt, this month under a strategy -- the "this
  month" action card. `nil` target means the whole budget was absorbed by
  minimum payments (nothing left to cascade).
  """
  def this_month_action(debts, monthly_budget, strategy) do
    with {:ok, %{months: [first | _]}} <- simulate(debts, monthly_budget, strategy) do
      {:ok, first}
    end
  end

  @doc """
  Cumulative monthly payment "freed" over time under a strategy: at each
  month, the gap between the original total minimum payments and the total
  minimum payments still owed on debts that remain active.
  """
  def freed_cashflow_over_time(debts, monthly_budget, strategy) do
    with {:ok, %{months: months}} <- simulate(debts, monthly_budget, strategy) do
      original_total =
        debts
        |> eligible()
        |> Enum.map(&Calculations.minimum_payment/1)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      freed =
        Enum.map(months, fn month ->
          remaining_minimums =
            month.lines
            |> Enum.filter(&Decimal.positive?(&1.ending_balance))
            |> Enum.map(& &1.minimum_payment)
            |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

          %{index: month.index, freed: Decimal.sub(original_total, remaining_minimums)}
        end)

      {:ok, freed}
    end
  end

  @doc """
  Applies a one-time lump sum this month and reports the interest and time
  saved versus not applying it, under the same strategy and budget.
  """
  def windfall_cascade(debts, monthly_budget, strategy, lump_sum) do
    with {:ok, baseline} <- simulate(debts, monthly_budget, strategy),
         {:ok, with_windfall} <-
           simulate(debts, monthly_budget, strategy, extra_first_month: lump_sum) do
      {:ok,
       %{
         interest_saved: Decimal.sub(baseline.total_interest, with_windfall.total_interest),
         months_saved: baseline.total_months - with_windfall.total_months
       }}
    end
  end
end
