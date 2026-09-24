defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddPreferencesToUsers do
  use Ecto.Migration

  # Per-user UI preferences (theme, ...) as one embedded map -- see
  # Accounts.UserPreferences. New preferences are fields on that embedded
  # schema, not new columns, so this should be the only migration they need.
  # Existing rows get `{}`, which loads as all-defaults.
  def change do
    alter table(:users) do
      add :preferences, :map, null: false, default: %{}
    end
  end
end
