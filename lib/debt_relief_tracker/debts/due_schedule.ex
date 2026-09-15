defmodule DebtReliefTracker.Debts.DueSchedule do
  @moduledoc """
  Pure due-date math for auto-logged payments (installment debts only --
  see `DebtReliefTracker.DuePayments`). No Ecto, no I/O -- takes plain
  structs/maps with the relevant fields and an explicit `today`, so it's
  cheap to unit test without wall-clock mocking. Shared by both auto-log
  modes: the `:automatic` scheduler polls `due?/2` and posts when true, and
  `:confirm` mode calls the same function fresh on every dashboard
  render/mutation to decide whether to show a "payment due" prompt -- no
  background process is needed for that mode at all.
  """

  @doc """
  The most recent occurrence of `due_day` that is on or before `today`,
  clamped to the day given month's actual last day (e.g. `due_day: 31` in
  February lands on the 28th/29th). If this month's clamped due date is
  still in the future relative to `today`, falls back to last month's
  clamped date instead -- so being a few days into a new month with last
  cycle's payment not yet posted/skipped still reads as "due", rather than
  jumping ahead to a future date.
  """
  def current_cycle_due_date(%{due_day: due_day}, today \\ Date.utc_today()) do
    this_month = clamped_date(today.year, today.month, due_day)

    if Date.compare(this_month, today) == :gt do
      {year, month} = previous_month(today.year, today.month)
      clamped_date(year, month, due_day)
    else
      this_month
    end
  end

  defp clamped_date(year, month, day) do
    Date.new!(year, month, min(day, Date.days_in_month(Date.new!(year, month, 1))))
  end

  defp previous_month(year, 1), do: {year - 1, 12}
  defp previous_month(year, month), do: {year, month - 1}

  @doc """
  Whether `debt` has an auto-log mode enabled, is an active installment
  debt, and the current cycle's due date has arrived without yet being
  posted or skipped. Compares dates (`last_due_handled_on` strictly before
  the current cycle's due date) rather than an exact day-match, so a missed
  check -- the container was stopped over the due day -- still catches up
  on the next check instead of silently skipping that cycle.
  """
  def due?(debt, today \\ Date.utc_today())

  def due?(%{auto_log_mode: :off}, _today), do: false
  def due?(%{type: :revolving}, _today), do: false
  def due?(%{status: :paid_off}, _today), do: false

  def due?(%{auto_log_mode: mode} = debt, today) when mode in [:confirm, :automatic] do
    cycle_due_date = current_cycle_due_date(debt, today)

    is_nil(debt.last_due_handled_on) or
      Date.compare(cycle_due_date, debt.last_due_handled_on) == :gt
  end

  def due?(_debt, _today), do: false
end
