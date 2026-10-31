defmodule DebtReliefTracker.Engine.DueSchedule do
  @moduledoc """
  Client-safe port of `DebtReliefTracker.Debts.DueSchedule`: due-date math for
  auto-logged installment payments, over `{year, month, day}` tuples and
  `Engine.Days`. Also provides `missed_cycles/2` for the client-side catch-up
  on open (docs/architecture/0007-e2ee.md): every due date since the last
  handled one, each with a deterministic payment id so two devices catching
  up produce the same records.
  """

  alias DebtReliefTracker.Engine.Days

  @doc "Most recent occurrence of `due_day` on or before `today`, clamped to the month's length."
  def current_cycle_due_date(%{due_day: due_day}, {year, month, _} = today) do
    this_month = Days.clamped({year, month, due_day})

    if Days.to_days(this_month) > Days.to_days(today) do
      {py, pm} = Days.previous_month(year, month)
      Days.clamped({py, pm, due_day})
    else
      this_month
    end
  end

  def due?(%{auto_log_mode: :off}, _today), do: false
  def due?(%{type: :revolving}, _today), do: false
  def due?(%{status: :paid_off}, _today), do: false

  def due?(%{auto_log_mode: mode} = debt, today) when mode in [:confirm, :automatic] do
    handled = Map.get(debt, :last_due_handled_on)

    is_nil(handled) or
      Days.to_days(current_cycle_due_date(debt, today)) > Days.to_days(handled)
  end

  def due?(_debt, _today), do: false

  @max_catch_up_cycles 24

  @doc """
  Every unhandled due date, oldest first, from just after
  `last_due_handled_on` up to the current cycle (capped at
  #{@max_catch_up_cycles}; a debt never handled yet only yields the current
  cycle, since there's no baseline to catch up from).
  """
  def missed_cycles(debt, today) do
    if due?(debt, today) do
      latest = current_cycle_due_date(debt, today)

      case Map.get(debt, :last_due_handled_on) do
        nil -> [latest]
        handled -> walk_back(debt, latest, Days.to_days(handled), [], 0)
      end
    else
      []
    end
  end

  defp walk_back(_debt, _date, _handled_days, acc, @max_catch_up_cycles), do: acc

  defp walk_back(debt, {year, month, _} = date, handled_days, acc, count) do
    if Days.to_days(date) > handled_days do
      {py, pm} = Days.previous_month(year, month)
      walk_back(debt, Days.clamped({py, pm, debt.due_day}), handled_days, [date | acc], count + 1)
    else
      acc
    end
  end

  @doc "Deterministic id for the auto-logged payment of `debt_id` due on `due_date`."
  def payment_id(debt_id, {y, m, d}), do: "#{debt_id}:#{y}-#{pad(m)}-#{pad(d)}"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
