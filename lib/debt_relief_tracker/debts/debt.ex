defmodule DebtReliefTracker.Debts.Debt do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.Encrypted

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "debts" do
    field :name, Encrypted.Binary, source: :name_enc
    field :type, Ecto.Enum, values: [:revolving, :installment]
    field :balance, Encrypted.Decimal, source: :balance_enc
    field :original_balance, Encrypted.Decimal, source: :original_balance_enc
    field :apr, Encrypted.Decimal, source: :apr_enc

    # Revolving: minimum = max(floor, rate * balance). Installment: fixed_payment.
    field :minimum_payment_floor, Encrypted.Decimal, source: :minimum_payment_floor_enc
    field :minimum_payment_rate, Encrypted.Decimal, source: :minimum_payment_rate_enc
    field :fixed_payment, Encrypted.Decimal, source: :fixed_payment_enc

    field :credit_limit, Encrypted.Decimal, source: :credit_limit_enc
    field :exclude_from_plan, :boolean, default: false

    # Interest-estimate reconciliation (docs/plan.md Phase 4): the last
    # confirmed statement balance/date the revolving-interest estimate
    # accrues from.
    field :statement_balance, Encrypted.Decimal, source: :statement_balance_enc
    field :statement_date, :date

    field :status, Ecto.Enum, values: [:active, :paid_off], default: :active
    field :paid_off_at, :utc_datetime

    field :position, :integer, default: 0

    # Auto-logged payments (installment debts only -- see DueSchedule/DuePayments):
    # `due_day` is the day of the month the fixed payment is due, `auto_log_mode`
    # is the per-debt opt-in (off by default), and `last_due_handled_on` is the
    # cycle date most recently posted or skipped, so a due-ness check never
    # double-fires for the same cycle.
    field :due_day, :integer
    field :auto_log_mode, Ecto.Enum, values: [:off, :confirm, :automatic], default: :off
    field :last_due_handled_on, :date

    belongs_to :workspace, Workspace

    # :utc_datetime_usec so `debts.ex`'s `order_by: [asc: d.position, asc:
    # d.inserted_at, asc: d.id]` tiebreak is actually meaningful -- ids are
    # now random UUIDs (see the UUID primary-key migration), so a
    # same-second `inserted_at` collision would otherwise fall through to
    # an arbitrary `id` order. No migration needed -- see the comment on
    # this same change in ActivityLog.Entry.
    timestamps(type: :utc_datetime_usec)
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
    :position,
    :due_day,
    :auto_log_mode,
    :last_due_handled_on
  ]

  def changeset(debt, attrs) do
    debt
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:balance, greater_than_or_equal_to: 0)
    |> validate_number(:original_balance, greater_than_or_equal_to: 0)
    |> validate_number(:apr, greater_than_or_equal_to: 0)
    |> validate_type_specific_fields()
    |> validate_auto_log_fields()
  end

  @doc "Transitions a debt to paid-off, stamping `paid_off_at`."
  def paid_off_changeset(debt) do
    change(debt, status: :paid_off, paid_off_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc "Stamps the cycle date a due payment was just posted or skipped for -- not user-facing, no other validations."
  def due_handled_changeset(debt, cycle_due_date) do
    change(debt, last_due_handled_on: cycle_due_date)
  end

  defp validate_type_specific_fields(changeset) do
    case get_field(changeset, :type) do
      :revolving -> validate_required(changeset, [:minimum_payment_rate])
      :installment -> validate_required(changeset, [:fixed_payment])
      _ -> changeset
    end
  end

  defp validate_auto_log_fields(changeset) do
    case get_field(changeset, :auto_log_mode) do
      :off ->
        changeset

      mode when mode in [:confirm, :automatic] ->
        changeset
        |> validate_type_for_auto_log()
        |> validate_required([:due_day])
        |> validate_number(:due_day, greater_than_or_equal_to: 1, less_than_or_equal_to: 31)

      _ ->
        changeset
    end
  end

  defp validate_type_for_auto_log(changeset) do
    if get_field(changeset, :type) == :installment do
      changeset
    else
      add_error(changeset, :auto_log_mode, "is only available for installment debts")
    end
  end
end
