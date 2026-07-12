defmodule DebtReliefTracker.Debts.Debt do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.Workspace

  schema "debts" do
    field :name, :string
    field :type, Ecto.Enum, values: [:revolving, :installment]
    field :balance, :decimal
    field :original_balance, :decimal
    field :apr, :decimal

    # Revolving: minimum = max(floor, rate * balance). Installment: fixed_payment.
    field :minimum_payment_floor, :decimal
    field :minimum_payment_rate, :decimal
    field :fixed_payment, :decimal

    field :credit_limit, :decimal
    field :exclude_from_plan, :boolean, default: false

    # Interest-estimate reconciliation (docs/plan.md Phase 4): the last
    # confirmed statement balance/date the revolving-interest estimate
    # accrues from.
    field :statement_balance, :decimal
    field :statement_date, :date

    field :status, Ecto.Enum, values: [:active, :paid_off], default: :active
    field :paid_off_at, :utc_datetime

    field :position, :integer, default: 0

    belongs_to :workspace, Workspace

    timestamps()
  end

  @required [:workspace_id, :name, :type, :balance, :apr]
  @optional [
    :original_balance,
    :minimum_payment_floor,
    :minimum_payment_rate,
    :fixed_payment,
    :credit_limit,
    :exclude_from_plan,
    :statement_balance,
    :statement_date,
    :position
  ]

  def changeset(debt, attrs) do
    debt
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:balance, greater_than_or_equal_to: 0)
    |> validate_number(:original_balance, greater_than_or_equal_to: 0)
    |> validate_number(:apr, greater_than_or_equal_to: 0)
    |> validate_type_specific_fields()
  end

  @doc "Transitions a debt to paid-off, stamping `paid_off_at`."
  def paid_off_changeset(debt) do
    change(debt, status: :paid_off, paid_off_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp validate_type_specific_fields(changeset) do
    case get_field(changeset, :type) do
      :revolving -> validate_required(changeset, [:minimum_payment_rate])
      :installment -> validate_required(changeset, [:fixed_payment])
      _ -> changeset
    end
  end
end
