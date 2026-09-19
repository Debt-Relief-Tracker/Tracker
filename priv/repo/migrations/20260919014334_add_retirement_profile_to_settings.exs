defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddRetirementProfileToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :current_age, :integer
      add :retirement_age, :integer
      add :current_retirement_savings, :decimal, null: false, default: 0
      add :monthly_retirement_contribution, :decimal, null: false, default: 0
      add :monthly_gross_income, :decimal, null: false, default: 0
      add :post_debt_investment_pct, :decimal, null: false, default: 15.0
      add :expected_annual_return_pct, :decimal, null: false, default: 7.0
      add :retirement_onboarding_dismissed, :boolean, null: false, default: false
    end
  end
end
