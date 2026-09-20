defmodule DebtReliefTracker.Repo.Sqlite.Migrations.BackfillEncryptedColumns do
  @moduledoc """
  Reads every plaintext column added by `add_encrypted_columns.exs`,
  encrypts it through `DebtReliefTracker.Vault`, writes the ciphertext into
  the matching `_enc` column, and immediately decrypts it back to verify
  the round-trip -- raising (and rolling back the whole transaction) on any
  mismatch. Plaintext columns are left untouched; a separate, later
  migration drops them once this has been verified against production.

  Written in raw SQL against the database directly (not through the
  `Debt`/`Payment`/etc. Ecto schemas, which by this point already declare
  these fields as `DebtReliefTracker.Encrypted.*` with `source: :*_enc` --
  going through them here would read/write the wrong column). Follows the
  same raw-SQL precedent as
  `priv/repo/migrations/20260919030100_migrate_retirement_data_off_settings.exs`.

  ## Decimal precision (SQLite only)

  SQLite has no native decimal type -- `:decimal` columns have NUMERIC
  affinity, so raw SQL reads return native SQLite storage classes: a
  float (`REAL`), an integer, or occasionally text. This mirrors exactly
  what `Ecto.Adapters.SQLite3.Codec.decimal_decode/1` does for every
  *normal* Ecto-mediated read of these columns today (`is_float ->
  Decimal.from_float/1`, `is_binary or is_integer -> Decimal.new/1`) --
  `to_decimal/1` below reproduces that exact logic, so this backfill
  produces the identical Decimal value the app already computes when
  loading these columns through Ecto, not a new source of precision loss.
  On Postgres, `:decimal` columns are native `NUMERIC` and postgrex always
  decodes them to `%Decimal{}` directly, even via a raw query -- handled by
  the same function's first clause.

  ## Ciphertext binding (SQLite only)

  Ciphertext is passed as a bound query parameter, never inlined as a SQL
  literal (unlike the UUID-migration's safe integer/UUID literals --
  arbitrary encrypted bytes can contain quote characters or invalid
  encoding). On SQLite it must be wrapped as `{:blob, binary}` so exqlite
  binds it as a BLOB; otherwise SQLite's `length()`/`typeof()` treat it as
  TEXT (harmless for byte-for-byte fidelity in ad hoc testing, but BLOB is
  the documented, unambiguous, correct binding and is what the
  `DebtReliefTracker.Encrypted.*` types themselves produce via
  `Ecto.Adapters.SQLite3.Codec.blob_encode/1`). Postgres has no such
  ambiguity -- a plain binary binds directly to `bytea`.
  """

  use Ecto.Migration

  alias DebtReliefTracker.Vault

  @fields %{
    "debts" => [
      binary: "name",
      decimal: "balance",
      decimal: "original_balance",
      decimal: "apr",
      decimal: "minimum_payment_floor",
      decimal: "minimum_payment_rate",
      decimal: "fixed_payment",
      decimal: "credit_limit",
      decimal: "statement_balance"
    ],
    "payments" => [
      decimal: "amount",
      decimal: "principal_portion",
      decimal: "interest_portion",
      binary: "note"
    ],
    "retirement_profiles" => [
      binary: "name",
      integer: "current_age",
      integer: "retirement_age",
      decimal: "current_retirement_savings",
      decimal: "monthly_retirement_contribution",
      decimal: "monthly_gross_income",
      decimal: "post_debt_investment_pct",
      decimal: "expected_annual_return_pct"
    ],
    "settings" => [decimal: "monthly_budget"],
    "activity_logs" => [map: "metadata"]
  }

  def up do
    # `Ecto.Migrator.with_repo/3` (which both `mix ecto.migrate` and a
    # production release's boot-time migrator use) starts only :ecto_sql
    # and the repo, not the full :debt_relief_tracker supervision tree --
    # so the Vault isn't necessarily running yet. Only stop it again
    # afterward if this migration is the one that started it: under a
    # release boot, the Vault is already supervised (started earlier in
    # DebtReliefTracker.Application's children) and must keep running for
    # the rest of the app, so `start_link/0` there just hits
    # `{:error, {:already_started, _}}` and `started_here?` is false.
    started_here? = start_vault_if_needed!()

    try do
      for {table, fields} <- @fields do
        backfill_table(table, fields)
      end
    after
      if started_here?, do: GenServer.stop(Vault)
    end
  end

  def down do
    for {table, fields} <- @fields, {_type, field} <- fields do
      repo().query!("UPDATE #{table} SET #{field}_enc = NULL")
    end
  end

  defp start_vault_if_needed! do
    case Vault.start_link() do
      {:ok, _pid} -> true
      {:error, {:already_started, _pid}} -> false
    end
  end

  defp backfill_table(table, fields) do
    columns = Enum.map(fields, fn {_type, field} -> field end)
    select_list = Enum.join(["id" | columns], ", ")

    %{rows: rows} = repo().query!("SELECT #{select_list} FROM #{table}")

    for [id | values] <- rows do
      fields
      |> Enum.zip(values)
      |> Enum.each(fn {{type, field}, value} ->
        backfill_field(table, id, field, type, value)
      end)
    end
  end

  defp backfill_field(_table, _id, _field, _type, nil), do: :ok

  defp backfill_field(table, id, field, type, value) do
    plaintext = serialize(type, value)
    ciphertext = Vault.encrypt!(plaintext)

    repo().query!(update_stmt(table, field), [blob_param(ciphertext), id])

    case Vault.decrypt!(ciphertext) do
      ^plaintext ->
        :ok

      other ->
        raise Ecto.MigrationError,
          message:
            "encryption backfill verification failed for #{table}.#{field} id=#{id}: " <>
              "decrypted #{inspect(other)}, expected #{inspect(plaintext)}"
    end
  end

  defp update_stmt(table, field) do
    case repo().__adapter__() do
      Ecto.Adapters.SQLite3 -> "UPDATE #{table} SET #{field}_enc = ? WHERE id = ?"
      Ecto.Adapters.Postgres -> "UPDATE #{table} SET #{field}_enc = $1 WHERE id = $2"
    end
  end

  defp blob_param(binary) do
    case repo().__adapter__() do
      Ecto.Adapters.SQLite3 -> {:blob, binary}
      Ecto.Adapters.Postgres -> binary
    end
  end

  # Matches DebtReliefTracker.Encrypted.Binary's before_encrypt (the
  # Cloak.Ecto.Type default: `to_string/1`).
  defp serialize(:binary, value), do: to_string(value)

  # Matches DebtReliefTracker.Encrypted.Integer's before_encrypt (also the
  # Cloak.Ecto.Type default: `to_string/1`).
  defp serialize(:integer, value), do: to_string(value)

  # Matches DebtReliefTracker.Encrypted.Decimal's before_encrypt
  # (Cloak.Ecto.Decimal: bare `Decimal.to_string/1`, default :scientific
  # format -- which only actually renders in exponent form for numbers
  # that need it; ordinary currency amounts print normally).
  defp serialize(:decimal, value), do: value |> to_decimal() |> Decimal.to_string()

  # Matches DebtReliefTracker.Encrypted.Map's before_encrypt
  # (Cloak.Ecto.Map: `vault.json_library().encode!/1`, i.e. Jason).
  defp serialize(:map, value), do: value |> to_map() |> Jason.encode!()

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(x) when is_float(x), do: Decimal.from_float(x)
  defp to_decimal(x) when is_integer(x) or is_binary(x), do: Decimal.new(x)

  # SQLite's :map columns are TEXT (JSON-encoded) at the raw-SQL level;
  # Postgres's are jsonb, which postgrex decodes to a map even in a raw
  # query.
  defp to_map(x) when is_map(x), do: x
  defp to_map(x) when is_binary(x), do: Jason.decode!(x)
end
