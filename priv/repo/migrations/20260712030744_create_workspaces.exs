defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces) do
      add :name, :string, null: false
      add :owner_user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:workspaces, [:owner_user_id])
  end
end
