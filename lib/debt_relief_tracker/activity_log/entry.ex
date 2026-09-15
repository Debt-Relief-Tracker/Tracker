defmodule DebtReliefTracker.ActivityLog.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.{User, Workspace}
  alias DebtReliefTracker.Debts.Debt

  schema "activity_logs" do
    field :action, Ecto.Enum,
      values: [
        :debt_added,
        :debt_updated,
        :debt_paid_off,
        :debt_deleted,
        :payment_logged,
        :payment_auto_logged,
        :due_payment_skipped
      ]

    field :metadata, :map, default: %{}

    belongs_to :workspace, Workspace
    belongs_to :user, User
    belongs_to :debt, Debt

    timestamps(updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:workspace_id, :user_id, :debt_id, :action, :metadata])
    |> validate_required([:workspace_id, :action])
  end
end
