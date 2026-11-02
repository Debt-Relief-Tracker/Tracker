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
  alias DebtReliefTracker.Settings.RetirementProfile

  @schema_version 1
  # ActivityLog.list_recent/2 requires a limit; this is "all of it".
  @activity_limit 100_000

  def schema_version, do: @schema_version

  @doc "The most activity entries `build/1` includes (see `E2EE.Migration`)."
  def activity_limit, do: @activity_limit

  def build(workspace) do
    %{
      schema_version: @schema_version,
      settings: settings(Settings.get_settings!(workspace)),
      debts: workspace |> Debts.list_debts() |> Enum.map(&debt/1),
      payments: workspace |> Payments.list_payments_for_workspace() |> Enum.map(&payment/1),
      activity: workspace |> ActivityLog.list_recent(@activity_limit) |> Enum.map(&activity/1),
      retirement_profiles:
        workspace |> Settings.list_retirement_profiles() |> Enum.map(&retirement_profile/1)
    }
  end

  defp settings(setting) do
    %{
      monthly_budget: Convert.to_cents(setting.monthly_budget),
      currency: setting.currency,
      budget_mode: to_string(setting.budget_mode),
      retirement_onboarding_dismissed: setting.retirement_onboarding_dismissed,
      updated_at: iso(setting.updated_at)
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
      inserted_at: iso(payment.inserted_at),
      updated_at: iso(payment.updated_at)
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

  defp retirement_profile(profile) do
    %{
      id: profile.id,
      # Set for a profile linked to a confirmed workspace member; nil for a
      # manual (no-account) profile.
      user_id: profile.user_id,
      # The resolved name to show: the linked user's display name, or the
      # typed-in name of a manual profile.
      display_name: RetirementProfile.display_name(profile),
      # Only manual profiles carry their own name / claim email.
      name: profile.name,
      claim_email: profile.claim_email,
      current_age: profile.current_age,
      retirement_age: profile.retirement_age,
      current_retirement_savings: Convert.to_cents(profile.current_retirement_savings),
      monthly_retirement_contribution: Convert.to_cents(profile.monthly_retirement_contribution),
      monthly_gross_income: Convert.to_cents(profile.monthly_gross_income),
      post_debt_investment_bp: Convert.percent_to_bp(profile.post_debt_investment_pct),
      expected_annual_return_bp: Convert.percent_to_bp(profile.expected_annual_return_pct),
      inserted_at: iso(profile.inserted_at),
      updated_at: iso(profile.updated_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%Date{} = date), do: Date.to_iso8601(date)
  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
end
