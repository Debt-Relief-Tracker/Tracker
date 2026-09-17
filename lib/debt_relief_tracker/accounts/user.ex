defmodule DebtReliefTracker.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    # nil for the single implicit user in no-auth mode; set to the OIDC
    # subject once a real identity provider is configured (ADR 0002).
    field :external_subject, :string
    field :email, :string
    field :display_name, :string
    field :tutorial_seen, :boolean, default: false

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:external_subject, :email, :display_name])
    |> validate_required([:display_name])
    |> unique_constraint(:external_subject)
  end

  def tutorial_changeset(user, attrs) do
    cast(user, attrs, [:tutorial_seen])
  end
end
