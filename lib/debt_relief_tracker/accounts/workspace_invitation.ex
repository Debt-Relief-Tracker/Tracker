defmodule DebtReliefTracker.Accounts.WorkspaceInvitation do
  @moduledoc """
  A pending share to an email address with no `User` account yet
  (docs/architecture/0002-auth-and-sharing-model.md). Fulfilled -- turned
  into a `WorkspaceMember` and deleted -- the moment that email completes
  its first OIDC login (`Accounts.get_or_create_user_from_oidc!/1`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.{User, Workspace}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_invitations" do
    field :email, :string
    belongs_to :workspace, Workspace
    belongs_to :invited_by, User, foreign_key: :invited_by_user_id

    timestamps()
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:workspace_id, :email, :invited_by_user_id])
    |> validate_required([:workspace_id, :email, :invited_by_user_id])
    |> unique_constraint([:workspace_id, :email])
  end
end
