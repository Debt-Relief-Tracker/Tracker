defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateDebts do
  use Ecto.Migration

  def change do
    create table(:debts) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # "revolving" (credit cards) or "installment" (auto loans, BNPL, etc.)
      add :type, :string, null: false
      add :balance, :decimal, null: false, default: 0
      add :apr, :decimal, null: false, default: 0

      # Revolving: minimum = max(floor, rate * balance). Installment: fixed_payment.
      add :minimum_payment_floor, :decimal
      add :minimum_payment_rate, :decimal
      add :fixed_payment, :decimal

      add :credit_limit, :decimal
      add :exclude_from_plan, :boolean, null: false, default: false

      # Revolving interest-estimate reconciliation (docs/plan.md Phase 4):
      # the last confirmed statement balance/date the estimate accrues from.
      add :statement_balance, :decimal
      add :statement_date, :date

      add :status, :string, null: false, default: "active"
      add :paid_off_at, :utc_datetime

      add :position, :integer, null: false, default: 0

      timestamps()
    end

    create index(:debts, [:workspace_id])
  end
end
