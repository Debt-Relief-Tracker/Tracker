defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:payments) do
      add :debt_id, references(:debts, on_delete: :delete_all), null: false
      add :amount, :decimal, null: false
      add :principal_portion, :decimal
      add :interest_portion, :decimal
      add :paid_on, :date, null: false
      # Attribution only (docs/architecture/0002-auth-and-sharing-model.md) --
      # never used for access control.
      add :logged_by_user_id, references(:users, on_delete: :nilify_all)
      add :note, :string

      timestamps()
    end

    create index(:payments, [:debt_id])
  end
end
