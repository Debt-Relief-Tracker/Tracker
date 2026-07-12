defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      # external_subject is nil for the single implicit user in no-auth mode
      # (docs/architecture/0002-auth-and-sharing-model.md); set once OIDC is
      # configured and a real identity logs in.
      add :external_subject, :string
      add :email, :string
      add :display_name, :string, null: false

      timestamps()
    end

    create unique_index(:users, [:external_subject])
  end
end
