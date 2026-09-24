defmodule DebtReliefTracker.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.WorkspaceMember

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    # nil for the single implicit user in no-auth mode; set to the OIDC
    # subject once a real identity provider is configured (ADR 0002).
    field :external_subject, :string
    field :email, :string
    field :display_name, :string
    field :tutorial_seen, :boolean, default: false
    field :is_admin, :boolean, default: false
    # true once the user has set a local-only name (no IdP write-back
    # available) -- login sync then leaves display_name alone. See
    # Accounts.display_name_editability/1.
    field :display_name_overridden, :boolean, default: false
    # Set programmatically only (never cast) -- see Accounts.record_login!/1
    # and Accounts.touch_last_seen/1; shown on the admin Users tab.
    field :last_login_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    has_many :workspace_members, WorkspaceMember

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

  @doc "Synced from an OIDC role claim on every login -- see Accounts.get_or_create_user_from_oidc!/1."
  def admin_changeset(user, attrs) do
    cast(user, attrs, [:is_admin])
  end

  @doc """
  Re-syncs IdP-sourced fields (`is_admin`, and `display_name` unless the user
  has overridden it) on every returning login -- see
  Accounts.get_or_create_user_from_oidc!/1.
  """
  def oidc_sync_changeset(user, attrs) do
    user
    |> cast(attrs, [:is_admin, :display_name])
    |> validate_required([:display_name])
  end

  @doc "The user-editable name form -- see Accounts.update_display_name/2."
  def display_name_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name])
    |> update_change(:display_name, &(&1 && String.trim(&1)))
    |> validate_required([:display_name])
    |> validate_length(:display_name, max: 100)
  end
end
