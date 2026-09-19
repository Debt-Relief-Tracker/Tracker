defmodule DebtReliefTracker.Planning.Retirement do
  @moduledoc """
  Projects retirement savings growth under each debt payoff strategy, to
  compare against a baseline of "keep doing what I'm doing." Pure functions
  over a `Settings.Setting` retirement profile and a list of debt structs --
  no Ecto, no I/O -- mirroring `Debts.Calculations`.

  Model: a strategy has a "debt-free month" (`total_months` from
  `Planning.simulate/4`). Before that month, the monthly contribution is
  whatever the user currently invests (`monthly_retirement_contribution`).
  From that month on, it switches to the recommended post-debt rate --
  `post_debt_investment_pct` of `monthly_gross_income` -- for the rest of the
  horizon to retirement. A strategy that pays off debt sooner switches to the
  (typically larger) post-debt contribution sooner, and compounds longer at
  that rate, which is what makes a faster strategy project a bigger nest egg.
  The baseline never switches -- it holds the current contribution flat for
  the whole horizon, since there's no debt-payoff event to trigger a change.
  """

  alias DebtReliefTracker.Planning
  alias Decimal, as: D

  @doc "Months between the profile's current age and its target retirement age."
  def months_to_retirement(%{current_age: current_age, retirement_age: retirement_age}) do
    (retirement_age - current_age) * 12
  end

  @doc "Baseline: current contribution held flat, no debt-payoff event ever changes it."
  def baseline_projection(settings) do
    project(
      settings.current_retirement_savings,
      baseline_contributions(settings),
      monthly_rate(settings)
    )
  end

  @doc "The baseline's flat monthly contribution schedule, one entry per month to retirement."
  def baseline_contributions(settings) do
    List.duplicate(settings.monthly_retirement_contribution, months_to_retirement(settings))
  end

  @doc """
  Projects retirement balance under a strategy: contributes
  `monthly_retirement_contribution` until the strategy's debts are fully
  paid off, then switches to `post_debt_investment_pct` of
  `monthly_gross_income` for the remainder of the horizon to retirement.

  Returns `{:ok, balances}` (a list of `months_to_retirement/1 + 1` Decimal
  balances, index 0 being the starting balance) or `{:error, :insufficient_budget
  | :did_not_converge}` when the strategy itself doesn't have a feasible plan
  at the given budget.
  """
  def strategy_projection(debts, settings, monthly_budget, strategy) do
    with {:ok, %{contributions: contributions}} <-
           strategy_projection_with_contributions(debts, settings, monthly_budget, strategy) do
      {:ok, project(settings.current_retirement_savings, contributions, monthly_rate(settings))}
    end
  end

  @doc """
  The monthly contribution schedule under a strategy (see `strategy_projection/4`):
  `monthly_retirement_contribution` until debt-free, then the post-debt rate
  for the rest of the horizon. Returns `{:ok, contributions}` or propagates
  `{:error, reason}` from the underlying simulation.
  """
  def strategy_contributions(debts, settings, monthly_budget, strategy) do
    months = months_to_retirement(settings)

    with {:ok, %{total_months: debt_free_month}} <-
           Planning.simulate(debts, monthly_budget, strategy) do
      {:ok, contribution_schedule(debt_free_month, settings, months)}
    end
  end

  @doc """
  Like `strategy_projection/4`, but also returns the underlying contribution
  schedule alongside the balances -- e.g. for a chart tooltip that shows both
  the projected balance and what's currently being contributed -- without
  computing the strategy's debt-free month twice.
  """
  def strategy_projection_with_contributions(debts, settings, monthly_budget, strategy) do
    with {:ok, contributions} <- strategy_contributions(debts, settings, monthly_budget, strategy) do
      balances =
        project(settings.current_retirement_savings, contributions, monthly_rate(settings))

      {:ok, %{balances: balances, contributions: contributions}}
    end
  end

  defp monthly_rate(settings) do
    settings.expected_annual_return_pct |> D.div(100) |> D.div(12)
  end

  # Growth applied to the PRIOR balance first, then that month's contribution
  # is added (end-of-month deposit convention -- this month's contribution
  # earns no growth until next month). Rounded to cents after each step.
  defp project(starting_balance, contributions, monthly_rate) do
    growth_factor = D.add(1, monthly_rate)

    balances =
      Enum.scan(contributions, starting_balance, fn contribution, balance ->
        balance |> D.mult(growth_factor) |> D.add(contribution) |> D.round(2)
      end)

    [D.round(starting_balance, 2) | balances]
  end

  # `debt_free_month` is `Planning.simulate/4`'s 1-based `total_months`: the
  # last month a payment was still being made. Months `1..debt_free_month`
  # use the current contribution; everything after switches to the post-debt
  # rate. With no debts at all, `debt_free_month` is `0`, so every month uses
  # the post-debt rate (there's nothing left to pay off, so the recommended
  # post-debt investing rate applies immediately). If retirement arrives
  # before the strategy finishes, the schedule is simply truncated to
  # `months` and never reaches the post-debt rate.
  defp contribution_schedule(debt_free_month, settings, months) do
    post_debt_contribution = post_debt_monthly_contribution(settings)

    for i <- 1..months do
      if i > debt_free_month,
        do: post_debt_contribution,
        else: settings.monthly_retirement_contribution
    end
  end

  defp post_debt_monthly_contribution(settings) do
    settings.monthly_gross_income |> D.mult(settings.post_debt_investment_pct) |> D.div(100)
  end
end
