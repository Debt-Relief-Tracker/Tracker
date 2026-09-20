defmodule DebtReliefTracker.Repo.Sqlite.Migrations.AddEncryptedColumns do
  use Ecto.Migration

  # Adds the BLOB (SQLite) / BYTEA (Postgres) columns the
  # DebtReliefTracker.Encrypted.* Ecto types write to. Plaintext columns are
  # left completely untouched here -- the next migration backfills them, and
  # a separate later migration drops the plaintext. Additive and reversible
  # on its own.
  #
  # All columns are nullable with no default: ciphertext has no meaningful
  # DB-level default, and SQLite cannot add a NOT NULL constraint to an
  # existing column without a full table rebuild. The NOT NULL guarantees
  # some of these columns carry today (e.g. `debts.name`, `debts.balance`,
  # `payments.amount`) already move up into the corresponding schema's
  # `validate_required/2` call, which is where every write in this app goes
  # through anyway.
  #
  # The "_enc" suffix is kept permanently (the schemas point at it via
  # `source: :<field>_enc`) rather than renamed back to the plaintext name
  # later -- that avoids ever renaming ~24 columns on a live database for a
  # purely cosmetic gain.
  def change do
    alter table(:debts) do
      add :name_enc, :binary
      add :balance_enc, :binary
      add :original_balance_enc, :binary
      add :apr_enc, :binary
      add :minimum_payment_floor_enc, :binary
      add :minimum_payment_rate_enc, :binary
      add :fixed_payment_enc, :binary
      add :credit_limit_enc, :binary
      add :statement_balance_enc, :binary
    end

    alter table(:payments) do
      add :amount_enc, :binary
      add :principal_portion_enc, :binary
      add :interest_portion_enc, :binary
      add :note_enc, :binary
    end

    alter table(:retirement_profiles) do
      add :name_enc, :binary
      add :current_age_enc, :binary
      add :retirement_age_enc, :binary
      add :current_retirement_savings_enc, :binary
      add :monthly_retirement_contribution_enc, :binary
      add :monthly_gross_income_enc, :binary
      add :post_debt_investment_pct_enc, :binary
      add :expected_annual_return_pct_enc, :binary
    end

    alter table(:settings) do
      add :monthly_budget_enc, :binary
    end

    alter table(:activity_logs) do
      add :metadata_enc, :binary
    end
  end
end
