defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateSupportEmails do
  use Ecto.Migration

  def change do
    create table(:support_emails, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :from, :string, null: false
      add :to, :string, null: false
      # subject/body/metadata are Cloak-encrypted at the Ecto.Type level
      # (docs/architecture/0005-field-level-encryption.md) -- opaque binary
      # at the DB layer, decrypted transparently by
      # DebtReliefTracker.Support.SupportEmail.
      add :subject_enc, :binary, null: false
      add :body_enc, :binary, null: false
      add :metadata_enc, :binary
      add :received_at, :utc_datetime_usec, null: false
      add :api_token_id, references(:api_tokens, type: :binary_id, on_delete: :nilify_all)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:support_emails, [:received_at])
  end
end
