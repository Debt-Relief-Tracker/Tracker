defmodule DebtReliefTracker.Payments.Payment do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payments" do
    field :amount, :decimal
    field :principal_portion, :decimal
    field :interest_portion, :decimal
    field :paid_on, :date
    field :note, :string

    belongs_to :debt, Debt
    belongs_to :logged_by, User, foreign_key: :logged_by_user_id

    timestamps()
  end

  @required [:debt_id, :amount, :paid_on]
  @optional [:principal_portion, :interest_portion, :logged_by_user_id, :note]

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:amount, greater_than: 0)
  end
end
