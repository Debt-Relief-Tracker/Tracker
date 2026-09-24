defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddActivityTimestampsToUsers do
  use Ecto.Migration

  # Admin Users tab (AdminLive): last_login_at is set on each OIDC callback,
  # last_seen_at (throttled) on LiveView mount -- see Accounts.record_login!/1
  # and Accounts.touch_last_seen/1. Nullable with no default, so this is a
  # cheap metadata-only ADD COLUMN on both adapters; existing rows read as
  # "Never".
  def change do
    alter table(:users) do
      add :last_login_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
    end
  end
end
