defmodule DebtReliefTracker.Payments.Payment do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Accounts.User
  alias DebtReliefTracker.Encrypted

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payments" do
    field :amount, Encrypted.Decimal, source: :amount_enc
    field :principal_portion, Encrypted.Decimal, source: :principal_portion_enc
    field :interest_portion, Encrypted.Decimal, source: :interest_portion_enc
    field :paid_on, :date
    field :note, Encrypted.Binary, source: :note_enc

    belongs_to :debt, Debt
    belongs_to :logged_by, User, foreign_key: :logged_by_user_id

    # :utc_datetime_usec so `payments.ex`'s `order_by: [desc: p.paid_on,
    # desc: p.inserted_at, desc: p.id]` tiebreak is actually meaningful --
    # see the same comment on this change in Debt/ActivityLog.Entry.
    timestamps(type: :utc_datetime_usec)
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
