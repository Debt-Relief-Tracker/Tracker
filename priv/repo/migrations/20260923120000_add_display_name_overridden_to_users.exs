defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddDisplayNameOverriddenToUsers do
  use Ecto.Migration

  # Set when a user edits their display name locally with no IdP write-back
  # available, so the per-login name sync (Accounts.get_or_create_user_from_oidc!/1)
  # stops overwriting it.
  def change do
    alter table(:users) do
      add :display_name_overridden, :boolean, null: false, default: false
    end
  end
end
