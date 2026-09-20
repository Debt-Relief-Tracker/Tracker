defmodule DebtReliefTracker.Settings.SiteSetting do
  @moduledoc """
  Global (not per-workspace) site identity/mailer config, edited from
  `/admin` -- a singleton row, unlike `DebtReliefTracker.Settings.Setting`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "site_settings" do
    field :site_name, :string
    field :from_name, :string
    field :from_email, :string
    field :welcome_emails_enabled, :boolean, default: true

    timestamps()
  end

  def changeset(site_setting, attrs) do
    cast(site_setting, attrs, [:site_name, :from_name, :from_email, :welcome_emails_enabled])
  end
end
