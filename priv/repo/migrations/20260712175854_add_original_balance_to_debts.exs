defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddOriginalBalanceToDebts do
  use Ecto.Migration

  def change do
    alter table(:debts) do
      add :original_balance, :decimal
    end
  end
end
