defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateRetirementProfiles do
  use Ecto.Migration

  def change do
    create table(:retirement_profiles) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :name, :string
      add :claim_email, :string
      add :current_age, :integer, null: false
      add :retirement_age, :integer, null: false
      add :current_retirement_savings, :decimal, null: false, default: 0
      add :monthly_retirement_contribution, :decimal, null: false, default: 0
      add :monthly_gross_income, :decimal, null: false, default: 0
      add :post_debt_investment_pct, :decimal, null: false, default: 15.0
      add :expected_annual_return_pct, :decimal, null: false, default: 7.0

      timestamps()
    end

    create index(:retirement_profiles, [:workspace_id])

    # One profile per confirmed member (owner or WorkspaceMember); unlimited
    # manual (user_id nil) profiles are allowed, so this is a partial index.
    # Left unnamed (default `<table>_<cols>_index`) rather than given a
    # custom name -- the SQLite adapter's UNIQUE constraint errors carry no
    # constraint name of their own, so Ecto reconstructs one from the
    # table/column names in the error message, which only matches a
    # changeset's `unique_constraint/3` when both sides use that same
    # default-derived name.
    create unique_index(:retirement_profiles, [:workspace_id, :user_id],
             where: "user_id IS NOT NULL"
           )

    # At most one manual profile per workspace can be waiting on a given
    # email, so Settings.claim_retirement_profiles/1 has a deterministic
    # target to convert once that email joins the workspace.
    create unique_index(:retirement_profiles, [:workspace_id, :claim_email],
             where: "claim_email IS NOT NULL"
           )
  end
end
