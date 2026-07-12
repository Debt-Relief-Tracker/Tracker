defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddBudgetModeToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :budget_mode, :string, null: false, default: "total"
    end
  end
end
