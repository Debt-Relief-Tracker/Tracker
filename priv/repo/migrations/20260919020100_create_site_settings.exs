defmodule DebtReliefTracker.Repo.Sqlite.Migrations.CreateSiteSettings do
  use Ecto.Migration

  def change do
    create table(:site_settings) do
      add :site_name, :string
      add :from_name, :string
      add :from_email, :string
      add :welcome_emails_enabled, :boolean, null: false, default: true

      timestamps()
    end
  end
end
