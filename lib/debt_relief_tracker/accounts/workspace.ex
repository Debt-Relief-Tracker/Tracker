defmodule DebtReliefTracker.Accounts.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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

  @doc "For renaming an existing workspace only -- owner is immutable after creation."
  def rename_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
