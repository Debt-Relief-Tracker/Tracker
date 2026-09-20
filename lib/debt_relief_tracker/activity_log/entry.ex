defmodule DebtReliefTracker.ActivityLog.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  alias DebtReliefTracker.Accounts.{User, Workspace}
  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.Encrypted

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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

    # metadata embeds plaintext debt names/payment amounts (see
    # DebtReliefTracker.Debts/DebtReliefTracker.Payments) -- encrypted for
    # the same reason those source fields are (docs/architecture/0005-field-level-encryption.md).
    # No schema-level `default:` -- see the comment on the numeric fields in
    # RetirementProfile for why; `ActivityLog.record/5` already supplies
    # `metadata: metadata` (defaulting to `%{}` itself) on every insert.
    field :metadata, Encrypted.Map, source: :metadata_enc

    belongs_to :workspace, Workspace
    belongs_to :user, User
    belongs_to :debt, Debt

    # :utc_datetime_usec (not the plain :utc_datetime the migration's
    # timestamps() DDL implies) so `inserted_at` alone can actually break
    # ties between entries created in the same second -- with ids now
    # random UUIDs (see the UUID primary-key migration), an `:id` tiebreak
    # no longer approximates insertion order, and second-precision
    # timestamps collide easily (e.g. add-debt-then-log-payment in the same
    # request). No migration needed: SQLite stores this column as plain
    # TEXT with no format enforcement, and Postgres's underlying `timestamp`
    # column already stores microsecond precision regardless of the Ecto
    # type -- this is a schema-level (app-only) change on both adapters.
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:workspace_id, :user_id, :debt_id, :action, :metadata])
    |> validate_required([:workspace_id, :action])
  end
end
