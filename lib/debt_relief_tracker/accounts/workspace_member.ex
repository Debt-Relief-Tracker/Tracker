defmodule DebtReliefTracker.Accounts.WorkspaceMember do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.{User, Workspace}

  schema "workspace_members" do
    field :role, Ecto.Enum, values: [:owner, :member]
    belongs_to :workspace, Workspace
    belongs_to :user, User

    timestamps()
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:workspace_id, :user_id, :role])
    |> validate_required([:workspace_id, :user_id, :role])
    |> unique_constraint([:workspace_id, :user_id])
  end
end
