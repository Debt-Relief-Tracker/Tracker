defmodule DebtReliefTracker.Engine.FromSnapshot do
  @moduledoc """
  Turns `DebtReliefTracker.Storage` snapshot debts (string enums, ISO date
  strings) into the plain maps the integer engine works on (atoms, day
  counts, date tuples). Client-safe: runs in the browser on the decrypted
  snapshot just as it does on the server.
  """

  alias DebtReliefTracker.Engine.Days

  def debts(snapshot), do: Enum.map(snapshot.debts, &debt/1)

  def debt(debt) do
    %{
      id: debt.id,
      name: debt.name,
      type: type(debt.type),
      status: status(debt.status),
      exclude_from_plan: debt.exclude_from_plan,
      balance: debt.balance,
      apr_bp: debt.apr_bp,
      fixed_payment: debt.fixed_payment,
      minimum_payment_floor: debt.minimum_payment_floor,
      minimum_payment_rate_bp: debt.minimum_payment_rate_bp,
      credit_limit: debt.credit_limit,
      statement_balance: debt.statement_balance,
      statement_days: debt.statement_date && Days.to_days(parse_date(debt.statement_date)),
      due_day: debt.due_day,
      auto_log_mode: auto_log_mode(debt.auto_log_mode),
      last_due_handled_on: debt.last_due_handled_on && parse_date(debt.last_due_handled_on)
    }
  end

  @doc "\"2026-10-31\" -> `{2026, 10, 31}`."
  def parse_date(iso) do
    [year, month, day] = String.split(iso, "-")
    {String.to_integer(year), String.to_integer(month), String.to_integer(day)}
  end

  defp type("revolving"), do: :revolving
  defp type("installment"), do: :installment

  defp status("active"), do: :active
  defp status("paid_off"), do: :paid_off

  defp auto_log_mode("off"), do: :off
  defp auto_log_mode("confirm"), do: :confirm
  defp auto_log_mode("automatic"), do: :automatic
end
