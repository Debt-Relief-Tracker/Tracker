defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateSentEmails do
  use Ecto.Migration

  def change do
    create table(:sent_emails) do
      add :template, :string, null: false
      add :to, :string, null: false
      add :subject, :string, null: false
      add :status, :string, null: false
      add :error, :string
      add :metadata, :map, null: false, default: %{}
      add :user_id, references(:users, on_delete: :nilify_all)

      timestamps(updated_at: false)
    end

    create index(:sent_emails, [:user_id])
  end
end
