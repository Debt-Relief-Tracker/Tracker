defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :monthly_budget, :decimal
      add :currency, :string, null: false, default: "USD"

      timestamps()
    end

    create unique_index(:settings, [:workspace_id])
  end
end
