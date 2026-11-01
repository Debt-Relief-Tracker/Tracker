defmodule DebtReliefTracker.Engine.Planning do
  @moduledoc """
  Client-safe port of `DebtReliefTracker.Planning`: strategy ordering and the
  month-by-month payoff simulation over plain maps, in integer cents (see
  `Engine.Calculations` for the debt map shape; planning also reads `:id`,
  `:status` and `:exclude_from_plan`).

  Semantics match the Decimal engine -- a strategy only picks the target
  order; every strategy pays all minimums, then cascades the remainder down
  the fixed order. The one intended difference is that each month's interest
  is rounded to a cent per debt, so totals can differ from the Decimal
  engine by fractions of a cent per debt-month (the parity tests bound it).
  """

  alias DebtReliefTracker.Engine.Calculations
  alias DebtReliefTracker.Engine.Money

  @max_months 600

  def eligible(debts) do
    Enum.filter(debts, fn debt ->
      debt.status != :paid_off and not Map.get(debt, :exclude_from_plan, false) and
        debt.balance > 0
    end)
  end

  def total_minimum_payments(debts) do
    debts |> eligible() |> Enum.reduce(0, &(Calculations.minimum_payment(&1) + &2))
  end

  def order(:cash_flow, debts), do: Enum.sort_by(debts, &cash_flow_ratio/1, :desc)
  def order(:snowball, debts), do: Enum.sort_by(debts, & &1.balance, :asc)
  def order(:avalanche, debts), do: Enum.sort_by(debts, & &1.apr_bp, :desc)

  # Minimum payment per dollar owed, scaled to an integer for a stable sort.
  defp cash_flow_ratio(%{balance: 0}), do: 0

  defp cash_flow_ratio(debt),
    do: div(Calculations.minimum_payment(debt) * 1_000_000_000, debt.balance)

  @doc """
  Returns `{:ok, %{months: [...], total_months: n, total_interest: cents}}`
  or `{:error, :insufficient_budget | :did_not_converge}`.
  """
  def simulate(debts, monthly_budget, strategy, opts \\ []) do
    ordered = order(strategy, eligible(debts))
    extra_first_month = Keyword.get(opts, :extra_first_month, 0)

    if ordered == [] do
      {:ok, %{months: [], total_months: 0, total_interest: 0}}
    else
      do_simulate(ordered, monthly_budget, extra_first_month, [], 0, 1)
    end
  end

  defp do_simulate(_debts, _budget, _extra, _months_acc, _total_interest, month)
       when month > @max_months,
       do: {:error, :did_not_converge}

  defp do_simulate(debts, budget, extra_first_month, months_acc, total_interest, month) do
    if Enum.all?(debts, &(&1.balance == 0)) do
      {:ok,
       %{
         months: Enum.reverse(months_acc),
         total_months: month - 1,
         total_interest: total_interest
       }}
    else
      extra_this_month = if month == 1, do: extra_first_month, else: 0

      case run_month(debts, budget, extra_this_month, month) do
        {:ok, updated, snapshot, month_interest} ->
          do_simulate(
            updated,
            budget,
            extra_first_month,
            [snapshot | months_acc],
            total_interest + month_interest,
            month + 1
          )

        :insufficient_budget ->
          {:error, :insufficient_budget}
      end
    end
  end

  defp run_month(debts, budget, extra_this_month, month_index) do
    accrued =
      Enum.map(debts, fn debt ->
        interest = Calculations.monthly_interest(debt.balance, debt.apr_bp)
        %{debt: %{debt | balance: debt.balance + interest}, interest: interest}
      end)

    minimums = Enum.map(accrued, fn %{debt: debt} -> Calculations.minimum_payment(debt) end)
    minimums_total = Enum.sum(minimums)
    available = budget + extra_this_month

    if available < minimums_total do
      :insufficient_budget
    else
      {payments, target_debt_id} = allocate(accrued, minimums, available - minimums_total)

      updated_debts =
        accrued
        |> Enum.zip(payments)
        |> Enum.map(fn {%{debt: debt}, payment} ->
          %{debt | balance: Money.clamp_non_negative(debt.balance - payment)}
        end)

      snapshot = %{
        index: month_index,
        target_debt_id: target_debt_id,
        lines:
          [accrued, minimums, payments]
          |> Enum.zip()
          |> Enum.map(fn {%{debt: debt, interest: interest}, minimum, payment} ->
            %{
              debt_id: debt.id,
              starting_balance: debt.balance,
              interest_accrued: interest,
              minimum_payment: minimum,
              payment: payment,
              ending_balance: Money.clamp_non_negative(debt.balance - payment)
            }
          end)
      }

      {:ok, updated_debts, snapshot, Enum.sum(Enum.map(accrued, & &1.interest))}
    end
  end

  defp allocate(accrued, minimums, cascade_pool) do
    {payments, _remaining, target_debt_id} =
      accrued
      |> Enum.map(& &1.debt)
      |> Enum.zip(minimums)
      |> Enum.reduce({[], cascade_pool, nil}, fn {debt, minimum}, {payments, pool, target} ->
        room = Money.clamp_non_negative(debt.balance - minimum)
        applied = min(pool, room)
        target = target || if(pool > 0 and room > 0, do: debt.id)
        {[minimum + applied | payments], pool - applied, target}
      end)

    {Enum.reverse(payments), target_debt_id}
  end

  def compare_strategies(debts, monthly_budget) do
    %{
      cash_flow: simulate(debts, monthly_budget, :cash_flow),
      snowball: simulate(debts, monthly_budget, :snowball),
      avalanche: simulate(debts, monthly_budget, :avalanche)
    }
  end

  def this_month_action(debts, monthly_budget, strategy) do
    with {:ok, %{months: [first | _]}} <- simulate(debts, monthly_budget, strategy) do
      {:ok, first}
    end
  end

  def freed_cashflow_over_time(debts, monthly_budget, strategy) do
    with {:ok, %{months: months}} <- simulate(debts, monthly_budget, strategy) do
      {:ok, freed_cashflow_from_months(debts, months)}
    end
  end

  @doc """
  `freed_cashflow_over_time/3` over the months of a simulation already run
  for `debts` (lets callers holding a `simulate/4` result skip re-running it).
  """
  def freed_cashflow_from_months(debts, months) do
    original_total = total_minimum_payments(debts)

    Enum.map(months, fn month ->
      remaining_minimums =
        month.lines
        |> Enum.filter(&(&1.ending_balance > 0))
        |> Enum.reduce(0, &(&1.minimum_payment + &2))

      %{index: month.index, freed: original_total - remaining_minimums}
    end)
  end

  def windfall_cascade(debts, monthly_budget, strategy, lump_sum) do
    with {:ok, baseline} <- simulate(debts, monthly_budget, strategy),
         {:ok, with_windfall} <-
           simulate(debts, monthly_budget, strategy, extra_first_month: lump_sum) do
      {:ok,
       %{
         interest_saved: baseline.total_interest - with_windfall.total_interest,
         months_saved: baseline.total_months - with_windfall.total_months
       }}
    end
  end
end
