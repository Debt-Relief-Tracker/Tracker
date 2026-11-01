defmodule DebtReliefTrackerWeb.Holo.Plan do
  @moduledoc """
  Everything `Holo.Components.PlanPanel` shows, derived from a `Storage`
  snapshot by the integer engine. Pure and client-safe (runs in the browser
  and in ExUnit); ports the plan-related helpers of `DashboardLive`
  (`assign_plan/1`, `displayed_budget/3`, `update_budget`, the stat cards,
  the this-month card and `push_chart_data/1`).

  `derive/4` runs the three strategy simulations once; `view/1` and
  `chart/3` read from its result, so one input change costs one set of
  simulations.
  """

  alias DebtReliefTracker.Engine.Calculations
  alias DebtReliefTracker.Engine.Charts
  alias DebtReliefTracker.Engine.Days
  alias DebtReliefTracker.Engine.FromSnapshot
  alias DebtReliefTracker.Engine.Planning
  alias DebtReliefTrackerWeb.Holo.Format
  alias DebtReliefTrackerWeb.Holo.Summary

  @month_abbrevs ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # --- budget -----------------------------------------------------------------

  @doc "The saved budget mode, `:total` (default) or `:margin`."
  def budget_mode(snapshot) do
    case snapshot.settings.budget_mode do
      "margin" -> :margin
      _total_or_nil -> :total
    end
  end

  @doc "Sum of this month's minimum payments over the plan's debts, in cents."
  def minimums(snapshot),
    do: snapshot |> FromSnapshot.debts() |> Planning.total_minimum_payments()

  @doc """
  The budget the plan runs on, in cents: the typed `draft` when it parses
  (a margin is added to the minimums, like `DashboardLive`'s
  `update_budget`), else the saved/default budget.
  """
  def effective_budget(snapshot, draft, mode) do
    case draft_total(snapshot, draft, mode) do
      {:ok, cents} -> cents
      :error -> Summary.monthly_budget(snapshot)
    end
  end

  @doc "A typed budget text as the total monthly budget in cents, or `:error`."
  def draft_total(_snapshot, nil, _mode), do: :error

  def draft_total(snapshot, draft, mode) do
    case Format.parse_cents_strict(draft) do
      {:ok, cents} when mode == :margin -> {:ok, minimums(snapshot) + cents}
      {:ok, cents} -> {:ok, cents}
      :error -> :error
    end
  end

  @doc "The budget input's text: the total, or in margin mode what's above the minimums."
  def budget_input_value(snapshot, :total),
    do: Format.plain_amount(Summary.monthly_budget(snapshot))

  def budget_input_value(snapshot, :margin),
    do: Format.plain_amount(Summary.monthly_budget(snapshot) - minimums(snapshot))

  def budget_label(:margin), do: "Additional margin"
  def budget_label(:total), do: "Monthly budget"

  # --- plan -------------------------------------------------------------------

  @doc """
  Runs every strategy's simulation for `budget` cents. `today` is a
  `{year, month, day}` tuple (balances are estimated as of it, and the
  payoff date counts from its month).
  """
  def derive(snapshot, strategy, budget, today) do
    debts = FromSnapshot.debts(snapshot)

    %{
      snapshot: snapshot,
      debts: debts,
      strategy: strategy,
      budget: budget,
      today: today,
      strategies: Planning.compare_strategies(debts, budget)
    }
  end

  @doc "Small, display-ready data for the panel's cards (kept in component state)."
  def view(derived) do
    %{
      this_month: this_month(derived),
      stats: stats(derived),
      currency: currency(derived.snapshot)
    }
  end

  @doc "`{message, config}` for `chart_type`, via `Engine.Charts.build/8`."
  def chart(derived, chart_type) do
    Charts.build(
      chart_type,
      derived.strategy,
      derived.strategies,
      derived.debts,
      derived.budget,
      derived.snapshot.payments,
      Map.get(derived.snapshot, :retirement_profiles, []),
      currency: currency(derived.snapshot)
    )
  end

  defp currency(snapshot), do: snapshot.settings.currency || "USD"

  # The "this month" card: either payment lines or one message. Unlike the
  # LiveView it never calls a plan error "add a debt" or a non-budget
  # problem a budget one (see Engine.Charts.plan_message/2).
  defp this_month(derived) do
    result = Map.get(derived.strategies, derived.strategy)

    case result do
      {:ok, %{months: [first | _]}} ->
        names = Map.new(derived.debts, &{&1.id, &1.name})

        lines =
          for line <- first.lines, line.payment > 0 do
            %{
              debt_id: line.debt_id,
              name: Map.get(names, line.debt_id, ""),
              payment: line.payment,
              extra: line.debt_id == first.target_debt_id
            }
          end

        %{lines: lines, message: nil}

      {:error, :insufficient_budget} ->
        %{
          lines: [],
          message: "Your monthly budget doesn't cover minimum payments yet -- increase it below."
        }

      {:error, :did_not_converge} ->
        %{
          lines: [],
          message:
            "This plan doesn't pay off within 50 years at this budget -- try raising it below."
        }

      _empty ->
        message =
          if derived.debts == [],
            do: "Add a debt to see your payoff plan.",
            else: "No active debts in your payoff plan right now."

        %{lines: [], message: message}
    end
  end

  # The summary stat cards (`DashboardLive.stat_cards/1`): totals project the
  # rest of the selected strategy's plan, not payment history.
  defp stats(derived) do
    result = Map.get(derived.strategies, derived.strategy)
    remaining = Calculations.total_remaining_balance(derived.debts, Days.to_days(derived.today))

    interest =
      case result do
        {:ok, %{total_interest: interest}} -> interest
        _ -> 0
      end

    {payoff_date, payoff_months} =
      case result do
        {:ok, %{total_months: months}} -> {month_label(derived.today, months), months}
        _ -> {"—", nil}
      end

    %{
      total_paid: remaining + interest,
      interest_paid: interest,
      debt_remaining: remaining,
      payoff_date: payoff_date,
      payoff_months: payoff_months,
      utilization_bp: Calculations.overall_credit_utilization_bp(derived.debts)
    }
  end

  @doc "\"Mon YYYY\" for the month `months` after `today`'s (`DashboardLive.payoff_date/1`)."
  def month_label({year, month, _day}, months) do
    total = year * 12 + (month - 1) + months
    "#{Enum.at(@month_abbrevs, rem(total, 12))} #{div(total, 12)}"
  end
end
