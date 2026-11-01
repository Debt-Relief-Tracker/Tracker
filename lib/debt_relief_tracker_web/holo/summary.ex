defmodule DebtReliefTrackerWeb.Holo.Summary do
  @moduledoc """
  Derived, display-ready numbers for the dashboard, computed from a
  `Storage` snapshot by the shared integer engine. Pure and client-safe, so
  it runs in the browser (including in E2EE mode) and in ExUnit.
  """

  alias DebtReliefTracker.Engine.Calculations
  alias DebtReliefTracker.Engine.FromSnapshot
  alias DebtReliefTracker.Engine.Planning

  @doc """
  The monthly budget in cents: the saved one, else 105% of this month's
  minimums rounded up to a whole dollar (or $200 with no debts), matching
  `DashboardLive`'s default.
  """
  def monthly_budget(snapshot) do
    case snapshot.settings.monthly_budget do
      nil -> default_budget(FromSnapshot.debts(snapshot))
      cents -> cents
    end
  end

  defp default_budget([]), do: 20_000

  defp default_budget(debts) do
    minimums = Planning.total_minimum_payments(debts)
    dollars = div(minimums * 105 + 9_999, 10_000)
    dollars * 100
  end

  @doc "Sum of all (estimated) balances still owed, as of `as_of_days`."
  def total_owed(snapshot, as_of_days),
    do: snapshot |> FromSnapshot.debts() |> Calculations.total_remaining_balance(as_of_days)

  @doc """
  The "this month" action card: `{:ok, %{target_name: name | nil, payment: cents, lines: [...]}}`
  or `{:error, reason}`.
  """
  def this_month(snapshot, strategy) do
    debts = FromSnapshot.debts(snapshot)

    with {:ok, month} <- first_month(debts, monthly_budget(snapshot), strategy) do
      names = Map.new(debts, &{&1.id, &1.name})
      target_line = Enum.find(month.lines, &(&1.debt_id == month.target_debt_id))

      {:ok,
       %{
         target_name: month.target_debt_id && Map.get(names, month.target_debt_id),
         payment: target_line && target_line.payment,
         lines: Enum.map(month.lines, &Map.put(&1, :name, Map.get(names, &1.debt_id)))
       }}
    end
  end

  # `Planning.this_month_action/3` returns `{:ok, %{months: []}}` (not a
  # first month) when no debt is eligible for the plan.
  defp first_month(debts, budget, strategy) do
    case Planning.simulate(debts, budget, strategy) do
      {:ok, %{months: [first | _]}} -> {:ok, first}
      {:ok, %{months: []}} -> {:error, :no_debts}
      {:error, _reason} = error -> error
    end
  end
end
