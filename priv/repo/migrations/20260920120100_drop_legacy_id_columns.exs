defmodule DebtReliefTracker.Repo.Sqlite.Migrations.DropLegacyIdColumns do
  use Ecto.Migration

  # Drops the `legacy_id` scaffolding column added by
  # convert_primary_keys_to_uuid.exs on every table. Kept as its own tiny,
  # trivially-reviewable migration -- run only after the app has been
  # verified running against the UUID schema -- rather than folded into the
  # much larger conversion migration, so the one genuinely irreversible
  # step here is small and easy to review on its own.
  def up do
    alter table(:users), do: remove(:legacy_id)
    alter table(:workspaces), do: remove(:legacy_id)
    alter table(:site_settings), do: remove(:legacy_id)
    alter table(:workspace_members), do: remove(:legacy_id)
    alter table(:workspace_invitations), do: remove(:legacy_id)
    alter table(:settings), do: remove(:legacy_id)
    alter table(:sent_emails), do: remove(:legacy_id)
    alter table(:debts), do: remove(:legacy_id)
    alter table(:payments), do: remove(:legacy_id)
    alter table(:activity_logs), do: remove(:legacy_id)
    alter table(:retirement_profiles), do: remove(:legacy_id)
  end

  # Irreversible: once `legacy_id` is gone, the original integer ids are
  # unrecoverable short of restoring the pre-migration database backup.
  def down do
    raise Ecto.MigrationError,
      message: "irreversible: legacy_id columns were dropped; restore from backup"
  end
end
