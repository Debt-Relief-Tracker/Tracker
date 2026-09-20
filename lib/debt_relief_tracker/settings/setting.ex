defmodule DebtReliefTracker.Settings.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.Workspace

  schema "settings" do
    field :monthly_budget, :decimal
    field :currency, :string, default: "USD"
    field :budget_mode, Ecto.Enum, values: [:total, :margin], default: :total
    field :retirement_onboarding_dismissed, :boolean, default: false

    belongs_to :workspace, Workspace

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :workspace_id,
      :monthly_budget,
      :currency,
      :budget_mode,
      :retirement_onboarding_dismissed
    ])
    |> validate_required([:workspace_id, :currency])
    |> unique_constraint(:workspace_id)
  end
end
