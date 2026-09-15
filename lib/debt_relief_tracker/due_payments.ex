defmodule DebtReliefTracker.DuePayments do
  @moduledoc """
  Orchestrates auto-logged payments (installment debts only): both the
  `:automatic`-mode scheduler and `:confirm`-mode's dashboard prompt share
  the due-ness check in `DebtReliefTracker.Debts.DueSchedule`, and post via
  `Payments.log_payment/5` -- no separate posting logic exists here.
  """

  alias DebtReliefTracker.{ActivityLog, Debts, Payments, Repo}
  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.Debts.{Debt, DueSchedule}

  @doc "Debts (already loaded for a workspace) with an unhandled due payment as of `today`."
  def due_debts(debts, today \\ Date.utc_today()) do
    Enum.filter(debts, &DueSchedule.due?(&1, today))
  end

  @doc """
  Posts `debt`'s fixed payment and stamps `last_due_handled_on` for the
  current cycle, in one transaction (so a crash mid-way -- or the balance
  update rejecting a negative balance -- can't leave a posted-but-unmarked
  cycle that gets double-posted on the next check). `user` is `nil` for the
  automatic-mode scheduler (no human logged it) -- `Payments.log_payment/5`
  already supports `logged_by_user_id: nil`, and the resulting
  `ActivityLog` entry is tagged `:payment_auto_logged` instead of
  `:payment_logged` so the activity log can tell the two apart.

  Returns `{:error, :not_due}` without writing anything if `debt` isn't
  actually due as of `today` -- guards against double-posting if called
  outside of a `due_debts/2`-filtered sweep.
  """
  def post_due_payment(%Workspace{} = workspace, user, %Debt{} = debt, today \\ Date.utc_today()) do
    if DueSchedule.due?(debt, today) do
      cycle_due_date = DueSchedule.current_cycle_due_date(debt, today)
      action = if is_nil(user), do: :payment_auto_logged, else: :payment_logged

      Repo.transaction(fn ->
        with {:ok, %{debt: updated_debt} = result} <-
               Payments.log_payment(
                 workspace,
                 user,
                 debt,
                 %{"amount" => debt.fixed_payment, "paid_on" => cycle_due_date},
                 action: action
               ),
             {:ok, final_debt} <- Debts.mark_due_handled(updated_debt, cycle_due_date) do
          %{result | debt: final_debt}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :not_due}
    end
  end

  @doc """
  Confirm-mode's "Skip this month": marks the current cycle handled without
  logging a payment.
  """
  def skip_due_payment(%Workspace{} = workspace, user, %Debt{} = debt, today \\ Date.utc_today()) do
    if DueSchedule.due?(debt, today) do
      cycle_due_date = DueSchedule.current_cycle_due_date(debt, today)

      Repo.transaction(fn ->
        with {:ok, updated} <- Debts.mark_due_handled(debt, cycle_due_date),
             {:ok, _entry} <-
               ActivityLog.record(workspace, user, :due_payment_skipped, updated, %{
                 "cycle_due_date" => Date.to_string(cycle_due_date)
               }) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :not_due}
    end
  end
end
