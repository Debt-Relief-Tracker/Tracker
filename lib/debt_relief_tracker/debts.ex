defmodule DebtReliefTracker.Debts do
  @moduledoc """
  Debts, scoped to a workspace. Every mutation writes a matching
  `DebtReliefTracker.ActivityLog` entry (docs/plan.md Phase 3).
  """

  import Ecto.Query, warn: false

  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.ActivityLog
  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.Debts.{Debt, Calculations}
  alias DebtReliefTracker.Payments

  def list_debts(%Workspace{id: workspace_id}) do
    from(d in Debt,
      where: d.workspace_id == ^workspace_id,
      order_by: [asc: d.position, asc: d.id]
    )
    |> Repo.all()
  end

  def get_debt!(%Workspace{id: workspace_id}, id) do
    Repo.get_by!(Debt, id: id, workspace_id: workspace_id)
  end

  def create_debt(%Workspace{} = workspace, user, attrs) do
    changeset =
      %Debt{}
      |> Debt.changeset(Map.put(attrs, "workspace_id", workspace.id))

    with {:ok, debt} <- Repo.insert(changeset) do
      ActivityLog.record(workspace, user, :debt_added, debt, %{"name" => debt.name})
      {:ok, debt}
    end
  end

  def update_debt(%Workspace{} = workspace, user, %Debt{} = debt, attrs) do
    changeset = Debt.changeset(debt, attrs)

    with {:ok, updated} <- Repo.update(changeset) do
      ActivityLog.record(workspace, user, :debt_updated, updated, %{"name" => updated.name})
      {:ok, updated}
    end
  end

  def mark_paid_off(%Workspace{} = workspace, user, %Debt{} = debt) do
    changeset = Debt.paid_off_changeset(debt)

    with {:ok, updated} <- Repo.update(changeset) do
      ActivityLog.record(workspace, user, :debt_paid_off, updated, %{"name" => updated.name})
      {:ok, updated}
    end
  end

  @doc """
  Outright deletes a debt (distinct from `mark_paid_off/3`, which just flips
  status/`paid_off_at` and keeps the debt and its history around). Its
  payments cascade-delete with it (`on_delete: :delete_all` on
  `payments.debt_id`). The activity log entry is recorded with `debt: nil` --
  logging it against the just-deleted id would violate the `activity_logs`
  foreign key, which only nilifies *existing* references on delete, not
  future inserts.
  """
  def delete_debt(%Workspace{} = workspace, user, %Debt{} = debt) do
    with {:ok, deleted} <- Repo.delete(debt) do
      ActivityLog.record(workspace, user, :debt_deleted, nil, %{"name" => deleted.name})
      {:ok, deleted}
    end
  end

  def change_debt(%Debt{} = debt, attrs \\ %{}), do: Debt.changeset(debt, attrs)

  @doc """
  Reconciles a debt to a newly-observed real balance (the "log all balances
  at once" flow, docs/plan.md Phase 5/Phase 4 interest modeling): the gap
  between the estimated current balance and the new one is logged as a
  payment (split into principal/interest using the accrued interest
  estimate), and the debt's statement baseline is reset so the `est.`
  overlay starts accruing fresh from here. If the new balance is higher than
  estimated (new charges), no payment is logged -- just the new baseline.
  """
  def reconcile_balance(
        %Workspace{} = workspace,
        user,
        %Debt{} = debt,
        new_balance,
        as_of \\ Date.utc_today()
      ) do
    new_balance = Calculations.to_decimal(new_balance)
    estimated = Calculations.estimated_balance(debt, as_of)
    implied_payment = Decimal.sub(estimated, new_balance)

    if Decimal.positive?(implied_payment) do
      interest = Decimal.min(Calculations.accrued_interest_estimate(debt, as_of), implied_payment)
      principal = Decimal.sub(implied_payment, interest)

      with {:ok, %{debt: updated}} <-
             Payments.log_payment(workspace, user, debt, %{
               "amount" => implied_payment,
               "interest_portion" => interest,
               "principal_portion" => principal,
               "paid_on" => as_of
             }) do
        update_debt(workspace, user, updated, %{
          "statement_balance" => new_balance,
          "statement_date" => as_of
        })
      end
    else
      update_debt(workspace, user, debt, %{
        "balance" => new_balance,
        "statement_balance" => new_balance,
        "statement_date" => as_of
      })
    end
  end

  @doc """
  Seeds the placeholder example debts from minimum.md into a brand-new,
  empty workspace. Only ever called once, at boot, for the no-auth default
  workspace (docs/plan.md Phase 3) -- workspaces created later via OIDC start
  empty.
  """
  def seed_placeholders_if_empty!(%Workspace{} = workspace) do
    if list_debts(workspace) == [] do
      Enum.each(placeholder_debts(), fn attrs ->
        {:ok, _debt} = create_debt(workspace, nil, attrs)
      end)
    end

    :ok
  end

  defp placeholder_debts do
    [
      %{
        "name" => "Visa Credit Card (example)",
        "type" => "revolving",
        "balance" => "4500.00",
        "apr" => "24.99",
        "minimum_payment_floor" => "35.00",
        "minimum_payment_rate" => "0.02",
        "position" => 0
      },
      %{
        "name" => "Store Card (example)",
        "type" => "revolving",
        "balance" => "1200.00",
        "apr" => "27.99",
        "minimum_payment_floor" => "25.00",
        "minimum_payment_rate" => "0.03",
        "position" => 1
      },
      %{
        "name" => "Auto Loan (example)",
        "type" => "installment",
        "balance" => "12000.00",
        "apr" => "6.50",
        "fixed_payment" => "350.00",
        "position" => 2
      }
    ]
  end
end
