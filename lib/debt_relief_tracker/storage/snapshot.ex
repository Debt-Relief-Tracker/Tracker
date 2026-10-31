defmodule DebtReliefTracker.Storage.Snapshot do
  @moduledoc """
  Builds a `DebtReliefTracker.Storage.snapshot/0` from the Ecto records.
  Server-side only (it reads Decimals); see `Storage` for the format.
  """

  alias DebtReliefTracker.ActivityLog
  alias DebtReliefTracker.Debts
  alias DebtReliefTracker.Engine.Convert
  alias DebtReliefTracker.Payments
  alias DebtReliefTracker.Settings

  @schema_version 1
  # ActivityLog.list_recent/2 requires a limit; this is "all of it".
  @activity_limit 100_000

  def schema_version, do: @schema_version

  def build(workspace) do
    %{
      schema_version: @schema_version,
      settings: settings(Settings.get_settings!(workspace)),
      debts: workspace |> Debts.list_debts() |> Enum.map(&debt/1),
      payments: workspace |> Payments.list_payments_for_workspace() |> Enum.map(&payment/1),
      activity: workspace |> ActivityLog.list_recent(@activity_limit) |> Enum.map(&activity/1)
    }
  end

  defp settings(setting) do
    %{
      monthly_budget: Convert.to_cents(setting.monthly_budget),
      currency: setting.currency,
      budget_mode: to_string(setting.budget_mode),
      retirement_onboarding_dismissed: setting.retirement_onboarding_dismissed
    }
  end

  defp debt(debt) do
    %{
      id: debt.id,
      name: debt.name,
      type: to_string(debt.type),
      status: to_string(debt.status),
      balance: Convert.to_cents(debt.balance),
      original_balance: Convert.to_cents(debt.original_balance),
      apr_bp: Convert.percent_to_bp(debt.apr),
      fixed_payment: Convert.to_cents(debt.fixed_payment),
      minimum_payment_floor: Convert.to_cents(debt.minimum_payment_floor),
      minimum_payment_rate_bp: Convert.fraction_to_bp(debt.minimum_payment_rate),
      credit_limit: Convert.to_cents(debt.credit_limit),
      exclude_from_plan: debt.exclude_from_plan,
      statement_balance: Convert.to_cents(debt.statement_balance),
      statement_date: iso(debt.statement_date),
      position: debt.position,
      due_day: debt.due_day,
      auto_log_mode: to_string(debt.auto_log_mode),
      last_due_handled_on: iso(debt.last_due_handled_on),
      paid_off_at: iso(debt.paid_off_at),
      updated_at: iso(debt.updated_at)
    }
  end

  defp payment(payment) do
    %{
      id: payment.id,
      debt_id: payment.debt_id,
      amount: Convert.to_cents(payment.amount),
      principal_portion: Convert.to_cents(payment.principal_portion),
      interest_portion: Convert.to_cents(payment.interest_portion),
      paid_on: iso(payment.paid_on),
      note: payment.note,
      logged_by_user_id: payment.logged_by_user_id,
      inserted_at: iso(payment.inserted_at)
    }
  end

  defp activity(entry) do
    %{
      id: entry.id,
      action: to_string(entry.action),
      debt_id: entry.debt_id,
      user_id: entry.user_id,
      metadata: entry.metadata,
      inserted_at: iso(entry.inserted_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%Date{} = date), do: Date.to_iso8601(date)
  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
end
