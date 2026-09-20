defmodule DebtReliefTracker.Repo.Sqlite.Migrations.MigrateRetirementDataOffSettings do
  use Ecto.Migration

  # One-time move of the old single-household retirement/income scalars off
  # `settings` and into a `retirement_profiles` row for the workspace owner
  # (the only person the old single row could plausibly represent). Written
  # in raw SQL rather than via the `Setting`/`RetirementProfile` Ecto schema
  # modules, since migrations shouldn't depend on app schemas that will keep
  # changing after this migration is written and run.
  def up do
    repo().query!("""
    INSERT INTO retirement_profiles
      (workspace_id, user_id, current_age, retirement_age, current_retirement_savings,
       monthly_retirement_contribution, monthly_gross_income, post_debt_investment_pct,
       expected_annual_return_pct, inserted_at, updated_at)
    SELECT s.workspace_id, w.owner_user_id, s.current_age, s.retirement_age,
           s.current_retirement_savings, s.monthly_retirement_contribution,
           s.monthly_gross_income, s.post_debt_investment_pct, s.expected_annual_return_pct,
           s.inserted_at, s.updated_at
    FROM settings s
    JOIN workspaces w ON w.id = s.workspace_id
    WHERE s.current_age IS NOT NULL AND s.retirement_age IS NOT NULL
    """)

    alter table(:settings) do
      remove :current_age
      remove :retirement_age
      remove :current_retirement_savings
      remove :monthly_retirement_contribution
      remove :monthly_gross_income
      remove :post_debt_investment_pct
      remove :expected_annual_return_pct
    end
  end

  # Irreversible: a real rollback would need to guess which
  # `retirement_profiles` row maps back to the single legacy `settings` row
  # if the household added more people since -- not well-defined. Back up
  # the database before running this migration.
  def down do
    raise Ecto.MigrationError,
      message: "irreversible: retirement data was moved to retirement_profiles"
  end
end
