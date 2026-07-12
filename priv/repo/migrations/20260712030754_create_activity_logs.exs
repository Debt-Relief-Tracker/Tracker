defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateActivityLogs do
  use Ecto.Migration

  def change do
    create table(:activity_logs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :debt_id, references(:debts, on_delete: :nilify_all)
      add :action, :string, null: false
      add :metadata, :map, null: false, default: %{}

      # No updated_at: activity log entries are immutable once written.
      timestamps(updated_at: false)
    end

    create index(:activity_logs, [:workspace_id])
    create index(:activity_logs, [:debt_id])
  end
end
