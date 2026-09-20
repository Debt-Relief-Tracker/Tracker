defmodule DebtReliefTracker.Repo.Sqlite.Migrations.DropPlaintextColumns do
  use Ecto.Migration

  # Drops the original plaintext columns now that their encrypted "_enc"
  # replacements have been backfilled and verified
  # (backfill_encrypted_columns.exs). Kept as its own small, trivially
  # reviewable migration -- the one genuinely irreversible step here --
  # rather than folded into the backfill, same reasoning as
  # convert_primary_keys_to_uuid.exs/drop_legacy_id_columns.exs.
  #
  # None of these columns are indexed or referenced by a foreign key or a
  # partial-index expression (the only indexes on these five tables are on
  # workspace_id/debt_id/user_id/claim_email, none of which are being
  # dropped here), so this is a plain, uncomplicated column removal on both
  # adapters.
  def up do
    alter table(:debts) do
      remove :name
      remove :balance
      remove :original_balance
      remove :apr
      remove :minimum_payment_floor
      remove :minimum_payment_rate
      remove :fixed_payment
      remove :credit_limit
      remove :statement_balance
    end

    alter table(:payments) do
      remove :amount
      remove :principal_portion
      remove :interest_portion
      remove :note
    end

    alter table(:retirement_profiles) do
      remove :name
      remove :current_age
      remove :retirement_age
      remove :current_retirement_savings
      remove :monthly_retirement_contribution
      remove :monthly_gross_income
      remove :post_debt_investment_pct
      remove :expected_annual_return_pct
    end

    alter table(:settings) do
      remove :monthly_budget
    end

    alter table(:activity_logs) do
      remove :metadata
    end
  end

  # Irreversible: once the plaintext columns are dropped, only the
  # DebtReliefTracker.Vault key can recover the data (via the "_enc"
  # columns) -- there is no automatic way back to a plaintext column.
  def down do
    raise Ecto.MigrationError,
      message: "irreversible: plaintext columns were dropped after encryption backfill"
  end
end
