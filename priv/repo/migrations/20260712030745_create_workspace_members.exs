defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateWorkspaceMembers do
  use Ecto.Migration

  def change do
    create table(:workspace_members) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "owner"

      timestamps()
    end

    create unique_index(:workspace_members, [:workspace_id, :user_id])
    create index(:workspace_members, [:user_id])
  end
end
