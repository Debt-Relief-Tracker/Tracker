defmodule DebtReliefTracker.Planning.Retirement do
  @moduledoc """
  Projects each household member's retirement savings growth under each
  debt payoff strategy, then sums them into one household series, to
  compare against a baseline of "keep doing what everyone's doing." Pure
  functions over a list of `Settings.RetirementProfile`-shaped profiles and
  a list of debt structs -- no Ecto, no I/O -- mirroring `Debts.Calculations`.

  Each person's own contributions and growth rate compound independently on
  their own age/retirement-age timeline: their contributions stop the
  moment *they* reach *their own* retirement age, even if others in the
  household keep contributing, and their balance keeps compounding
  (untouched, no further deposits) for whatever's left of the household's
  overall horizon after that. The debt payoff plan itself is household-wide
  (there's one debt-free month, from `Planning.simulate/4`, shared by
  everyone) -- but each person switches to their own post-debt contribution
  rate, off their own income, once that month arrives.
  """

  alias DebtReliefTracker.Planning
  alias Decimal, as: D

  @doc "Months between the profile's current age and its target retirement age."
  def months_to_retirement(%{current_age: current_age, retirement_age: retirement_age}) do
    (retirement_age - current_age) * 12
  end

  @doc "The household horizon: the longest of every profile's own months-to-retirement."
  def combined_months_to_retirement(profiles) do
    profiles |> Enum.map(&months_to_retirement/1) |> Enum.max()
  end

  @doc """
  Baseline: each profile's current contribution held flat until *their*
  retirement, with no debt-payoff event ever changing it, summed across the
  household.
  """
  def baseline_projection(profiles) do
    total_months = combined_months_to_retirement(profiles)

    profiles
    |> Enum.map(fn profile ->
      profile
      |> project(baseline_contributions_for(profile), monthly_rate(profile))
      |> pad_balances(monthly_rate(profile), total_months)
    end)
    |> sum_series()
  end

  @doc "The baseline's combined monthly contribution schedule, one entry per month to the household horizon."
  def baseline_contributions(profiles) do
    total_months = combined_months_to_retirement(profiles)

    profiles
    |> Enum.map(&pad_contributions(baseline_contributions_for(&1), total_months))
    |> sum_series()
  end

  defp baseline_contributions_for(profile) do
    List.duplicate(profile.monthly_retirement_contribution, months_to_retirement(profile))
  end

  @doc """
  Projects the household's combined retirement balance under a strategy:
  each person contributes their own current amount until the strategy's
  debts are fully paid off, then switches to their own
  `post_debt_investment_pct` of their own `monthly_gross_income` for the
  rest of their own horizon.

  Returns `{:ok, balances}` (household-wide, `combined_months_to_retirement/1 + 1`
  Decimal balances, index 0 being the combined starting balance) or
  `{:error, :insufficient_budget | :did_not_converge}` when the strategy
  itself doesn't have a feasible plan at the given budget.
  """
  def strategy_projection(debts, profiles, monthly_budget, strategy) do
    with {:ok, %{balances: balances}} <-
           strategy_projection_with_contributions(debts, profiles, monthly_budget, strategy) do
      {:ok, balances}
    end
  end

  @doc """
  The household's combined monthly contribution schedule under a strategy
  (see `strategy_projection/4`). Returns `{:ok, contributions}` or
  propagates `{:error, reason}` from the underlying simulation.
  """
  def strategy_contributions(debts, profiles, monthly_budget, strategy) do
    with {:ok, %{contributions: contributions}} <-
           strategy_projection_with_contributions(debts, profiles, monthly_budget, strategy) do
      {:ok, contributions}
    end
  end

  @doc """
  Like `strategy_projection/4`, but also returns the underlying combined
  contribution schedule alongside the balances -- e.g. for a chart tooltip
  that shows both the projected balance and what's currently being
  contributed -- without computing the strategy's debt-free month twice.
  """
  def strategy_projection_with_contributions(debts, profiles, monthly_budget, strategy) do
    total_months = combined_months_to_retirement(profiles)

    with {:ok, %{total_months: debt_free_month}} <-
           Planning.simulate(debts, monthly_budget, strategy) do
      {balances, contributions} =
        profiles
        |> Enum.map(fn profile ->
          own_months = months_to_retirement(profile)
          contributions = contribution_schedule(debt_free_month, profile, own_months)
          rate = monthly_rate(profile)
          balances = profile |> project(contributions, rate) |> pad_balances(rate, total_months)

          {balances, pad_contributions(contributions, total_months)}
        end)
        |> Enum.unzip()

      {:ok, %{balances: sum_series(balances), contributions: sum_series(contributions)}}
    end
  end

  defp monthly_rate(profile) do
    profile.expected_annual_return_pct |> D.div(100) |> D.div(12)
  end

  # Growth applied to the PRIOR balance first, then that month's contribution
  # is added (end-of-month deposit convention -- this month's contribution
  # earns no growth until next month). Rounded to cents after each step.
  defp project(profile, contributions, monthly_rate) do
    growth_factor = D.add(1, monthly_rate)

    balances =
      Enum.scan(contributions, profile.current_retirement_savings, fn contribution, balance ->
        balance |> D.mult(growth_factor) |> D.add(contribution) |> D.round(2)
      end)

    [D.round(profile.current_retirement_savings, 2) | balances]
  end

  # `debt_free_month` is `Planning.simulate/4`'s 1-based `total_months`: the
  # last month a payment was still being made. Months `1..debt_free_month`
  # use the current contribution; everything after switches to this
  # person's post-debt rate. With no debts at all, `debt_free_month` is `0`,
  # so every month uses the post-debt rate. If this person's own retirement
  # arrives before the strategy finishes, the schedule is simply truncated
  # to `months` and never reaches the post-debt rate.
  defp contribution_schedule(debt_free_month, profile, months) do
    post_debt_contribution = post_debt_monthly_contribution(profile)

    for i <- 1..months do
      if i > debt_free_month,
        do: post_debt_contribution,
        else: profile.monthly_retirement_contribution
    end
  end

  defp post_debt_monthly_contribution(profile) do
    profile.monthly_gross_income |> D.mult(profile.post_debt_investment_pct) |> D.div(100)
  end

  # Extends a shorter-horizon person's balance series out to the household
  # horizon: after their own retirement month, their money stays invested
  # and keeps compounding at their own rate, it just stops receiving new
  # contributions.
  defp pad_balances(balances, monthly_rate, total_months) do
    own_months = length(balances) - 1

    if own_months >= total_months do
      Enum.take(balances, total_months + 1)
    else
      growth_factor = D.add(1, monthly_rate)
      missing = total_months - own_months

      extension =
        Enum.scan(1..missing, List.last(balances), fn _i, balance ->
          balance |> D.mult(growth_factor) |> D.round(2)
        end)

      balances ++ extension
    end
  end

  defp pad_contributions(contributions, total_months) do
    missing = total_months - length(contributions)

    if missing <= 0 do
      Enum.take(contributions, total_months)
    else
      contributions ++ List.duplicate(D.new(0), missing)
    end
  end

  defp sum_series(series_lists) do
    series_lists
    |> Enum.zip()
    |> Enum.map(fn tuple -> tuple |> Tuple.to_list() |> Enum.reduce(&D.add/2) end)
  end
end
