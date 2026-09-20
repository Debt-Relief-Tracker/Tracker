defmodule DebtReliefTracker.Payments do
  @moduledoc """
  Logging payments against a debt. The principal/interest split is decided
  by the caller (the `Debts.Calculations` engine, Phase 4, or an explicit
  override) -- this context just persists it and applies it to the debt's
  balance, and records the matching `DebtReliefTracker.ActivityLog` entry.
  """

  import Ecto.Query, warn: false

  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.ActivityLog
  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Payments.Payment

  def list_payments_for_debt(%Debt{id: debt_id}) do
    from(p in Payment,
      where: p.debt_id == ^debt_id,
      order_by: [desc: p.paid_on, desc: p.inserted_at, desc: p.id]
    )
    |> Repo.all()
  end

  @doc """
  All payments across every debt in a workspace (for lifetime
  interest/principal totals, and CSV export), most recent first. Preloads
  `:debt` since both consumers display/reference the debt's name.
  """
  def list_payments_for_workspace(%Workspace{id: workspace_id}) do
    from(p in Payment,
      join: d in assoc(p, :debt),
      where: d.workspace_id == ^workspace_id,
      order_by: [desc: p.paid_on, desc: p.inserted_at, desc: p.id],
      preload: [debt: d]
    )
    |> Repo.all()
  end

  @doc """
  Logs a payment against `debt` and reduces its balance by the principal
  portion (defaulting to the full amount when no split is given). Runs in a
  transaction: if the resulting balance would be negative, the whole
  operation is rolled back.

  Accepts an `:action` option (default `:payment_logged`) so callers
  posting on a debt owner's behalf -- e.g. `DuePayments`'s auto-log
  scheduler -- can record a distinguishable `ActivityLog` action instead of
  the normal human-driven one.
  """
  def log_payment(%Workspace{} = workspace, user, %Debt{} = debt, attrs, opts \\ []) do
    action = Keyword.get(opts, :action, :payment_logged)
    principal = principal_portion(attrs)

    # Always persist the computed split, not just whatever the caller
    # happened to pass in -- otherwise a payment logged with only "amount"
    # (the common case: the simple "log payment" form) stores a nil
    # principal_portion, silently zeroing it out of lifetime interest/
    # principal reporting even though the debt's balance was correctly
    # reduced by it.
    attrs =
      attrs
      |> Map.put("debt_id", debt.id)
      |> Map.update("principal_portion", principal, fn
        v when v in [nil, ""] -> principal
        v -> v
      end)

    Repo.transaction(fn ->
      with {:ok, payment} <- Repo.insert(Payment.changeset(%Payment{}, attrs)),
           {:ok, updated_debt} <-
             Repo.update(
               Debt.changeset(debt, %{"balance" => Decimal.sub(debt.balance, principal)})
             ) do
        {:ok, _entry} =
          ActivityLog.record(workspace, user, action, updated_debt, %{
            "amount" => Decimal.to_string(payment.amount)
          })

        %{payment: payment, debt: updated_debt}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp principal_portion(%{"principal_portion" => p}) when p not in [nil, ""],
    do: Decimal.new(to_string(p))

  defp principal_portion(%{"amount" => amount}), do: Decimal.new(to_string(amount))
end
