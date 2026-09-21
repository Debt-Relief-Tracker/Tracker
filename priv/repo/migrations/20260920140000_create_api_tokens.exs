defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :token_hash, :string, null: false
      add :last_four, :string, null: false
      # JSON-encoded list of scope strings, not {:array, :string} -- see
      # docs/architecture/0001-dual-database-adapter.md (no Postgres-only
      # types) and DebtReliefTracker.Types.StringList.
      add :scopes, :string, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token_hash])
  end
end
