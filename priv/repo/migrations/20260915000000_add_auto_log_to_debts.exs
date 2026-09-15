defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddAutoLogToDebts do
  use Ecto.Migration

  def change do
    alter table(:debts) do
      add :due_day, :integer
      add :auto_log_mode, :string, null: false, default: "off"
      add :last_due_handled_on, :date
    end
  end
end
