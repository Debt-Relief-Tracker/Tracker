defmodule DebtReliefTracker.Accounts.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.User

  schema "workspaces" do
    field :name, :string
    belongs_to :owner, User, foreign_key: :owner_user_id

    timestamps()
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :owner_user_id])
    |> validate_required([:name, :owner_user_id])
  end
end
