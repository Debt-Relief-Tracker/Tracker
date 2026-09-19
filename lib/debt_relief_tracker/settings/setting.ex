defmodule DebtReliefTracker.Settings.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.Workspace

  schema "settings" do
    field :monthly_budget, :decimal
    field :currency, :string, default: "USD"
    field :budget_mode, Ecto.Enum, values: [:total, :margin], default: :total

    field :current_age, :integer
    field :retirement_age, :integer
    field :current_retirement_savings, :decimal, default: 0
    field :monthly_retirement_contribution, :decimal, default: 0
    field :monthly_gross_income, :decimal, default: 0
    field :post_debt_investment_pct, :decimal, default: 15.0
    field :expected_annual_return_pct, :decimal, default: 7.0
    field :retirement_onboarding_dismissed, :boolean, default: false

    belongs_to :workspace, Workspace

    timestamps()
  end

  @retirement_fields [
    :current_age,
    :retirement_age,
    :current_retirement_savings,
    :monthly_retirement_contribution,
    :monthly_gross_income,
    :post_debt_investment_pct,
    :expected_annual_return_pct
  ]

  def changeset(setting, attrs) do
    setting
    |> cast(
      attrs,
      [:workspace_id, :monthly_budget, :currency, :budget_mode, :retirement_onboarding_dismissed] ++
        @retirement_fields
    )
    |> validate_required([:workspace_id, :currency])
    |> unique_constraint(:workspace_id)
    |> validate_retirement_fields()
  end

  @doc "Requires the full retirement profile -- used by the onboarding/edit modal."
  def retirement_changeset(setting, attrs) do
    setting
    |> cast(attrs, @retirement_fields)
    |> validate_required(@retirement_fields)
    |> validate_retirement_fields()
  end

  defp validate_retirement_fields(changeset) do
    changeset
    |> validate_number(:current_age, greater_than_or_equal_to: 0, less_than_or_equal_to: 120)
    |> validate_number(:retirement_age, greater_than_or_equal_to: 1, less_than_or_equal_to: 120)
    |> validate_number(:current_retirement_savings, greater_than_or_equal_to: 0)
    |> validate_number(:monthly_retirement_contribution, greater_than_or_equal_to: 0)
    |> validate_number(:monthly_gross_income, greater_than_or_equal_to: 0)
    |> validate_number(:post_debt_investment_pct,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:expected_annual_return_pct,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 30
    )
    |> validate_retirement_age_after_current_age()
  end

  defp validate_retirement_age_after_current_age(changeset) do
    current_age = get_field(changeset, :current_age)
    retirement_age = get_field(changeset, :retirement_age)

    if is_integer(current_age) and is_integer(retirement_age) and retirement_age <= current_age do
      add_error(changeset, :retirement_age, "must be greater than current age")
    else
      changeset
    end
  end
end
