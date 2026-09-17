defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddTutorialSeenToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :tutorial_seen, :boolean, null: false, default: false
    end
  end
end
