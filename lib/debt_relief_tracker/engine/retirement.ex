defmodule DebtReliefTracker.Engine.Retirement do
  @moduledoc """
  Client-safe port of `DebtReliefTracker.Planning.Retirement`: projects each
  household member's retirement savings under each debt payoff strategy and
  sums them into one household series, in integer cents. No `Decimal`, floats
  or `Date`, so it runs unchanged in the browser (docs/architecture/0007-e2ee.md).

  ## Inputs

    * `profiles` -- the snapshot's `retirement_profiles` list, used as is
      (`Storage` snapshot shape). Fields read: `:current_age`,
      `:retirement_age`, `:current_retirement_savings`,
      `:monthly_retirement_contribution`, `:monthly_gross_income` (cents),
      `:post_debt_investment_bp` and `:expected_annual_return_bp` (basis points
      of a percent: 7% -> `700`). Callers must pass at least one profile for
      the horizon functions to be meaningful; `[]` yields a horizon of `0`.
    * `debts` -- engine debt maps, i.e. `Engine.FromSnapshot.debts(snapshot)`.
    * `monthly_budget` -- integer cents; `strategy` -- `:cash_flow | :snowball | :avalanche`.

  ## Outputs (shape-stable)

  Every series is a plain list of integer cents. Balance series have
  `combined_months_to_retirement(profiles) + 1` entries, index 0 being the
  combined starting balance (so index `n` is the balance after month `n`).
  Contribution series have `combined_months_to_retirement(profiles)` entries,
  index `i` being month `i + 1`'s combined contribution. The strategy
  functions return `{:ok, ...}` or `{:error, :insufficient_budget |
  :did_not_converge}` straight from `Engine.Planning.simulate/3`.

  ## Rounding (differs from the Decimal engine, documented and bounded)

  Same model as the Decimal original: growth is applied to the prior balance
  first, then the month's contribution is added (end-of-month deposit), and
  the balance is rounded to the cent after each month. Differences:

    * the monthly growth `balance * (1 + annual_bp / 120_000)` is rounded half
      up to a cent *before* the contribution is added (the Decimal version
      rounds once after adding it; contributions are whole cents so the
      results agree except in rare half-cent ties);
    * the post-debt contribution `income * pct` is rounded to a cent (the
      Decimal version carries sub-cent precision into that month's sum);
    * the debt-free month comes from the integer payoff simulation, which
      itself rounds interest per debt-month (see `Engine.Planning`) -- month
      counts match the Decimal engine exactly in the parity fixtures.

  Each step therefore differs by at most about one cent, and a cent of drift
  compounds with the account's growth. `parity_test.exs` bounds the final
  difference by the sum of the compounded growth factors over the horizon.
  """

  alias DebtReliefTracker.Engine.Money
  alias DebtReliefTracker.Engine.Planning

  @doc "Months between the profile's current age and its target retirement age."
  def months_to_retirement(%{current_age: current_age, retirement_age: retirement_age}) do
    (retirement_age - current_age) * 12
  end

  @doc "The household horizon: the longest of every profile's own months-to-retirement (`0` for no profiles)."
  def combined_months_to_retirement(profiles) do
    Enum.reduce(profiles, 0, fn profile, longest -> max(longest, months_to_retirement(profile)) end)
  end

  @doc """
  Baseline: each profile's current contribution held flat until *their*
  retirement, with no debt-payoff event ever changing it, summed across the
  household. Returns the combined balance series.
  """
  def baseline_projection(profiles) do
    total_months = combined_months_to_retirement(profiles)

    profiles
    |> Enum.map(fn profile ->
      contributions = baseline_contributions_for(profile)
      project_padded(profile, contributions, total_months)
    end)
    |> sum_series()
  end

  @doc "The baseline's combined monthly contribution series, one entry per month to the household horizon."
  def baseline_contributions(profiles) do
    total_months = combined_months_to_retirement(profiles)

    profiles
    |> Enum.map(&pad_contributions(baseline_contributions_for(&1), total_months))
    |> sum_series()
  end

  @doc """
  The household's combined retirement balance series under a strategy: each
  person contributes their current amount until the strategy's debts are paid
  off, then switches to `post_debt_investment_bp` of their own monthly gross
  income for the rest of their own horizon.

  Returns `{:ok, balances}` or `{:error, :insufficient_budget | :did_not_converge}`.
  """
  def strategy_projection(debts, profiles, monthly_budget, strategy) do
    with {:ok, %{balances: balances}} <-
           strategy_projection_with_contributions(debts, profiles, monthly_budget, strategy) do
      {:ok, balances}
    end
  end

  @doc """
  The household's combined monthly contribution series under a strategy.
  Returns `{:ok, contributions}` or the same errors as `strategy_projection/4`.
  """
  def strategy_contributions(debts, profiles, monthly_budget, strategy) do
    with {:ok, %{contributions: contributions}} <-
           strategy_projection_with_contributions(debts, profiles, monthly_budget, strategy) do
      {:ok, contributions}
    end
  end

  @doc """
  Both series at once (one payoff simulation): `{:ok, %{balances: [...],
  contributions: [...]}}` or `{:error, reason}`.
  """
  def strategy_projection_with_contributions(debts, profiles, monthly_budget, strategy) do
    total_months = combined_months_to_retirement(profiles)

    with {:ok, %{total_months: debt_free_month}} <-
           Planning.simulate(debts, monthly_budget, strategy) do
      per_person =
        Enum.map(profiles, fn profile ->
          contributions =
            contribution_schedule(debt_free_month, profile, months_to_retirement(profile))

          {project_padded(profile, contributions, total_months),
           pad_contributions(contributions, total_months)}
        end)

      {:ok,
       %{
         balances: per_person |> Enum.map(&elem(&1, 0)) |> sum_series(),
         contributions: per_person |> Enum.map(&elem(&1, 1)) |> sum_series()
       }}
    end
  end

  defp baseline_contributions_for(profile) do
    List.duplicate(profile.monthly_retirement_contribution, months_to_retirement(profile))
  end

  # One person's balances over their own horizon, then extended to the
  # household horizon: after their retirement their money stays invested and
  # keeps compounding at their own rate, with no new contributions.
  defp project_padded(profile, contributions, total_months) do
    own = project(profile, contributions)
    own_months = length(contributions)

    if own_months >= total_months do
      Enum.take(own, total_months + 1)
    else
      own ++ grow(List.last(own), profile.expected_annual_return_bp, total_months - own_months)
    end
  end

  # [starting balance | balance after each month]. Growth first, then the
  # end-of-month contribution.
  defp project(profile, contributions) do
    start = profile.current_retirement_savings
    bp = profile.expected_annual_return_bp

    {balances, _last} =
      Enum.map_reduce(contributions, start, fn contribution, balance ->
        next = grow_once(balance, bp) + contribution
        {next, next}
      end)

    [start | balances]
  end

  defp grow(balance, bp, months) do
    {balances, _last} =
      Enum.map_reduce(1..months, balance, fn _month, current ->
        next = grow_once(current, bp)
        {next, next}
      end)

    balances
  end

  # balance * (1 + bp / 120_000), half up. (bp is basis points of the annual
  # percent: 12 months * 100 * 100.)
  defp grow_once(balance, bp), do: Money.mul_div(balance, 120_000 + bp, 120_000)

  # `debt_free_month` is the simulation's 1-based `total_months`: the last
  # month a payment was still being made. Months up to it use the current
  # contribution; later months use the post-debt amount. With no debts it is
  # `0`, so every month uses the post-debt amount. A person retiring before
  # the debt-free month never reaches the post-debt amount.
  defp contribution_schedule(debt_free_month, profile, months) do
    post_debt = post_debt_monthly_contribution(profile)

    Enum.map(1..months, fn month ->
      if month > debt_free_month, do: post_debt, else: profile.monthly_retirement_contribution
    end)
  end

  # income cents * (pct_bp / 100 %) / 100 = income * pct_bp / 10_000.
  defp post_debt_monthly_contribution(profile) do
    Money.mul_div(profile.monthly_gross_income, profile.post_debt_investment_bp, 10_000)
  end

  defp pad_contributions(contributions, total_months) do
    missing = total_months - length(contributions)

    if missing <= 0,
      do: Enum.take(contributions, total_months),
      else: contributions ++ List.duplicate(0, missing)
  end

  # Element-wise sum of equal-length series (a single series is returned as is).
  defp sum_series([]), do: []
  defp sum_series([first | rest]), do: Enum.reduce(rest, first, &add_series(&2, &1))

  defp add_series([a | as], [b | bs]), do: [a + b | add_series(as, bs)]
  defp add_series([], []), do: []
end
