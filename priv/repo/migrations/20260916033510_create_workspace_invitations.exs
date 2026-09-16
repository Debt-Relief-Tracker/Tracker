defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateWorkspaceInvitations do
  use Ecto.Migration

  def change do
    create table(:workspace_invitations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :invited_by_user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:workspace_invitations, [:workspace_id, :email])
    create index(:workspace_invitations, [:email])
  end
end
