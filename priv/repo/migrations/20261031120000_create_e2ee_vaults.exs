defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateE2eeVaults do
  @moduledoc """
  Server side of the end-to-end encrypted mode (docs/architecture/0007-e2ee.md).

  Additive only: two NEW tables, no existing table is touched, nothing is
  backfilled. The server stores opaque ciphertext and key wraps; it never
  parses them. Reversible: `change/0` drops both tables on rollback (they are
  empty unless E2EE has been turned on).

    * `e2ee_vaults` -- one row per workspace (the PK is the workspace id).
      `rev` is the compare-and-swap counter; `blob` is the AES-GCM envelope
      of the whole encrypted document.
    * `e2ee_key_wraps` -- the vault key wrapped by each unlock method. The
      `wrapped_key` envelope (`v1.<iv>.<ct>`) carries its own IV, so there is
      deliberately no separate iv column. `kind` is validated in the
      changeset, not by a DB enum, so one migration serves SQLite and
      Postgres.
  """
  use Ecto.Migration

  def change do
    create table(:e2ee_vaults, primary_key: false) do
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :rev, :integer, null: false, default: 1
      add :blob, :binary, null: false
      add :format_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create table(:e2ee_key_wraps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false
      add :label, :string
      add :credential_id, :string
      add :kdf_params, :string
      add :salt, :string
      add :wrapped_key, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:e2ee_key_wraps, [:workspace_id])
    # NULL credential_ids (passphrase/recovery wraps) are distinct in both
    # SQLite and Postgres, so this only constrains passkey wraps.
    create unique_index(:e2ee_key_wraps, [:workspace_id, :credential_id])
  end
end
