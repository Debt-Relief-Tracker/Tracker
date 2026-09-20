defmodule DebtReliefTracker.Repo.Sqlite.Migrations.ConvertPrimaryKeysToUuid do
  @moduledoc """
  Converts every table's primary key from an integer auto-increment to a
  UUID (`:binary_id`), and every foreign key that references it, so raw
  database access can no longer trivially enumerate/correlate rows by
  sequential id.

  This uses the classic SQLite table-rebuild pattern (`CREATE TABLE new ->
  INSERT ... SELECT -> DROP old -> RENAME`) on BOTH adapters rather than
  branching, because SQLite has no `ALTER COLUMN`/`MODIFY` at all -- this is
  the only shape that works identically on SQLite and Postgres from the
  same migration file.

  UUIDs are generated in Elixir (`Ecto.UUID.generate/0`) and inlined as SQL
  literals -- identical text on both adapters, no `pgcrypto` extension
  needed. Every `INSERT ... SELECT` names its columns explicitly (never
  `SELECT *`, since column order/set differs between the old and new
  tables) and copies actual column values straight from the old table
  through the database engine itself -- no user data (names, notes,
  amounts, etc.) is ever re-serialized through Elixir string interpolation
  here. Only the freshly generated UUID and the numeric legacy id (both
  self-generated, safe values -- never user input) are interpolated into
  SQL text.

  A scaffolding `legacy_id` column (the original integer id) is kept on
  every new table. This is what makes this migration genuinely reversible
  (see `down/0`) and lets `sent_emails.metadata`'s embedded integer ids be
  remapped safely. `legacy_id` is dropped by a later, separate,
  intentionally-irreversible migration
  (`drop_legacy_id_columns.exs`) once the app has been verified running
  against the new schema.
  """

  use Ecto.Migration

  # sent_emails.metadata (written by UserNotifier) embeds these integer ids
  # as plain JSON values -- not FK-enforced, so a normal column/FK migration
  # never touches them. Accounts.resend_email/1 reads them back via
  # Repo.get/2, which raises Ecto.Query.CastError (not nil) on a stale
  # integer id once the target table's PK is :binary_id, so these must be
  # remapped to their new UUIDs (or dropped, if the referenced parent row no
  # longer exists) as part of this migration.
  @id_keys ~w(workspace_id inviter_id user_id invitation_id)
  @id_key_tables_new %{
    "workspace_id" => "workspaces_new",
    "inviter_id" => "users_new",
    "user_id" => "users_new",
    "invitation_id" => "workspace_invitations_new"
  }
  @id_key_tables_final %{
    "workspace_id" => "workspaces",
    "inviter_id" => "users",
    "user_id" => "users",
    "invitation_id" => "workspace_invitations"
  }

  @final_tables ~w(users workspaces site_settings workspace_members workspace_invitations
                   settings sent_emails debts payments activity_logs retirement_profiles)

  @not_null_fks [
    {"workspaces_new", "owner_user_id"},
    {"workspace_members_new", "workspace_id"},
    {"workspace_members_new", "user_id"},
    {"workspace_invitations_new", "workspace_id"},
    {"workspace_invitations_new", "invited_by_user_id"},
    {"settings_new", "workspace_id"},
    {"debts_new", "workspace_id"},
    {"payments_new", "debt_id"},
    {"activity_logs_new", "workspace_id"},
    {"retirement_profiles_new", "workspace_id"}
  ]

  # {old_table, old_column, new_table, new_column} -- nullable FKs, checked
  # by comparing the count of non-null values rather than expecting zero.
  @nullable_fks [
    {"sent_emails", "user_id", "sent_emails_new", "user_id"},
    {"payments", "logged_by_user_id", "payments_new", "logged_by_user_id"},
    {"activity_logs", "user_id", "activity_logs_new", "user_id"},
    {"activity_logs", "debt_id", "activity_logs_new", "debt_id"},
    {"retirement_profiles", "user_id", "retirement_profiles_new", "user_id"}
  ]

  def up do
    create_new_tables()
    # Ecto's migration DSL queues DDL commands and only actually applies
    # them to the database at a `flush/0` call (or at the end of the
    # migration). The raw SQL below runs immediately and reads/writes the
    # "_new" tables, so it needs them to already exist.
    flush()
    copy_data_forward()
    remap_sent_emails_metadata_forward()
    verify_before_cutover!()
    drop_old_tables()
    rename_new_tables()
    create_indexes()
  end

  # Reversal is only possible while every row still carries its original
  # integer id in `legacy_id` -- i.e. nothing has been created since the
  # cutover. If that holds, this is the up/0 sequence run in reverse: undo
  # the metadata remap, rebuild the original integer-PK tables, copy data
  # back using `legacy_id` as the restored `id`, drop the UUID tables, and
  # rename back.
  def down do
    guard_no_post_cutover_rows!()
    remap_sent_emails_metadata_backward()
    create_old_tables()
    # See the comment in up/0 -- copy_data_back/0 below is raw SQL that
    # needs the "_old" tables (just queued above) to actually exist.
    flush()
    copy_data_back()
    verify_after_rollback!()
    drop_uuid_tables()
    rename_old_tables()
    create_indexes()
    # reset_autoincrement_counters/0 queries the final table names by raw
    # SQL, so the rename above must actually have been applied first.
    flush()
    reset_autoincrement_counters()
  end

  # ------------------------------------------------------------------
  # up/0 -- step 1: create the eleven "_new" tables (UUID PK, legacy_id
  # scaffolding, every original column reproduced exactly). No indexes yet
  # -- those are created in create_indexes/0, after the rename, so they get
  # their original default-derived names (several `unique_constraint/2`
  # calls in the app depend on matching those names).
  # ------------------------------------------------------------------

  defp create_new_tables do
    create table(:users_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer
      add :external_subject, :string
      add :email, :string
      add :display_name, :string, null: false
      add :tutorial_seen, :boolean, null: false, default: false
      add :is_admin, :boolean, null: false, default: false
      timestamps()
    end

    create table(:workspaces_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer
      add :name, :string, null: false

      add :owner_user_id,
          references(:users_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "workspaces_owner_user_id_fkey"
          ),
          null: false

      timestamps()
    end

    create table(:site_settings_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer
      add :site_name, :string
      add :from_name, :string
      add :from_email, :string
      add :welcome_emails_enabled, :boolean, null: false, default: true
      timestamps()
    end

    create table(:workspace_members_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer

      add :workspace_id,
          references(:workspaces_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "workspace_members_workspace_id_fkey"
          ),
          null: false

      add :user_id,
          references(:users_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "workspace_members_user_id_fkey"
          ),
          null: false

      add :role, :string, null: false, default: "owner"
      timestamps()
    end

    create table(:workspace_invitations_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer

      add :workspace_id,
          references(:workspaces_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "workspace_invitations_workspace_id_fkey"
          ),
          null: false

      add :email, :string, null: false

      add :invited_by_user_id,
          references(:users_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "workspace_invitations_invited_by_user_id_fkey"
          ),
          null: false

      timestamps()
    end

    create table(:settings_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer

      add :workspace_id,
          references(:workspaces_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "settings_workspace_id_fkey"
          ),
          null: false

      add :monthly_budget, :decimal
      add :currency, :string, null: false, default: "USD"
      add :budget_mode, :string, null: false, default: "total"
      add :retirement_onboarding_dismissed, :boolean, null: false, default: false
      timestamps()
    end

    create table(:sent_emails_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer
      add :template, :string, null: false
      add :to, :string, null: false
      add :subject, :string, null: false
      add :status, :string, null: false
      add :error, :string
      add :metadata, :map, null: false, default: %{}

      add :user_id,
          references(:users_new,
            type: :binary_id,
            on_delete: :nilify_all,
            name: "sent_emails_user_id_fkey"
          )

      timestamps(updated_at: false)
    end

    create table(:debts_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer

      add :workspace_id,
          references(:workspaces_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "debts_workspace_id_fkey"
          ),
          null: false

      add :name, :string, null: false
      add :type, :string, null: false
      add :balance, :decimal, null: false, default: 0
      add :apr, :decimal, null: false, default: 0
      add :minimum_payment_floor, :decimal
      add :minimum_payment_rate, :decimal
      add :fixed_payment, :decimal
      add :credit_limit, :decimal
      add :exclude_from_plan, :boolean, null: false, default: false
      add :statement_balance, :decimal
      add :statement_date, :date
      add :status, :string, null: false, default: "active"
      add :paid_off_at, :utc_datetime
      add :position, :integer, null: false, default: 0
      add :original_balance, :decimal
      add :due_day, :integer
      add :auto_log_mode, :string, null: false, default: "off"
      add :last_due_handled_on, :date
      timestamps()
    end

    create table(:payments_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer

      add :debt_id,
          references(:debts_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "payments_debt_id_fkey"
          ),
          null: false

      add :amount, :decimal, null: false
      add :principal_portion, :decimal
      add :interest_portion, :decimal
      add :paid_on, :date, null: false

      add :logged_by_user_id,
          references(:users_new,
            type: :binary_id,
            on_delete: :nilify_all,
            name: "payments_logged_by_user_id_fkey"
          )

      add :note, :string
      timestamps()
    end

    create table(:activity_logs_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer

      add :workspace_id,
          references(:workspaces_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "activity_logs_workspace_id_fkey"
          ),
          null: false

      add :user_id,
          references(:users_new,
            type: :binary_id,
            on_delete: :nilify_all,
            name: "activity_logs_user_id_fkey"
          )

      add :debt_id,
          references(:debts_new,
            type: :binary_id,
            on_delete: :nilify_all,
            name: "activity_logs_debt_id_fkey"
          )

      add :action, :string, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(updated_at: false)
    end

    create table(:retirement_profiles_new, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :legacy_id, :integer

      add :workspace_id,
          references(:workspaces_new,
            type: :binary_id,
            on_delete: :delete_all,
            name: "retirement_profiles_workspace_id_fkey"
          ),
          null: false

      add :user_id,
          references(:users_new,
            type: :binary_id,
            on_delete: :nilify_all,
            name: "retirement_profiles_user_id_fkey"
          )

      add :name, :string
      add :claim_email, :string
      add :current_age, :integer, null: false
      add :retirement_age, :integer, null: false
      add :current_retirement_savings, :decimal, null: false, default: 0
      add :monthly_retirement_contribution, :decimal, null: false, default: 0
      add :monthly_gross_income, :decimal, null: false, default: 0
      add :post_debt_investment_pct, :decimal, null: false, default: 15.0
      add :expected_annual_return_pct, :decimal, null: false, default: 7.0
      timestamps()
    end
  end

  # ------------------------------------------------------------------
  # up/0 -- step 2: copy every row across, oldest-id-first, in dependency
  # order (parents before children). `JOIN` is used for NOT NULL FKs,
  # `LEFT JOIN` for nullable ones (so a null FK doesn't drop the row).
  # ------------------------------------------------------------------

  defp copy_data_forward do
    copy_forward("users", fn old_id, uuid ->
      """
      INSERT INTO users_new
        (id, legacy_id, external_subject, email, display_name, tutorial_seen, is_admin, inserted_at, updated_at)
      SELECT '#{uuid}', u.id, u.external_subject, u.email, u.display_name, u.tutorial_seen, u.is_admin, u.inserted_at, u.updated_at
      FROM users u WHERE u.id = #{old_id}
      """
    end)

    copy_forward("site_settings", fn old_id, uuid ->
      """
      INSERT INTO site_settings_new
        (id, legacy_id, site_name, from_name, from_email, welcome_emails_enabled, inserted_at, updated_at)
      SELECT '#{uuid}', ss.id, ss.site_name, ss.from_name, ss.from_email, ss.welcome_emails_enabled, ss.inserted_at, ss.updated_at
      FROM site_settings ss WHERE ss.id = #{old_id}
      """
    end)

    copy_forward("workspaces", fn old_id, uuid ->
      """
      INSERT INTO workspaces_new (id, legacy_id, name, owner_user_id, inserted_at, updated_at)
      SELECT '#{uuid}', w.id, w.name, un.id, w.inserted_at, w.updated_at
      FROM workspaces w
      JOIN users_new un ON un.legacy_id = w.owner_user_id
      WHERE w.id = #{old_id}
      """
    end)

    copy_forward("workspace_members", fn old_id, uuid ->
      """
      INSERT INTO workspace_members_new (id, legacy_id, workspace_id, user_id, role, inserted_at, updated_at)
      SELECT '#{uuid}', wm.id, wn.id, un.id, wm.role, wm.inserted_at, wm.updated_at
      FROM workspace_members wm
      JOIN workspaces_new wn ON wn.legacy_id = wm.workspace_id
      JOIN users_new un ON un.legacy_id = wm.user_id
      WHERE wm.id = #{old_id}
      """
    end)

    copy_forward("workspace_invitations", fn old_id, uuid ->
      """
      INSERT INTO workspace_invitations_new (id, legacy_id, workspace_id, email, invited_by_user_id, inserted_at, updated_at)
      SELECT '#{uuid}', wi.id, wn.id, wi.email, iun.id, wi.inserted_at, wi.updated_at
      FROM workspace_invitations wi
      JOIN workspaces_new wn ON wn.legacy_id = wi.workspace_id
      JOIN users_new iun ON iun.legacy_id = wi.invited_by_user_id
      WHERE wi.id = #{old_id}
      """
    end)

    copy_forward("settings", fn old_id, uuid ->
      """
      INSERT INTO settings_new (id, legacy_id, workspace_id, monthly_budget, currency, budget_mode, retirement_onboarding_dismissed, inserted_at, updated_at)
      SELECT '#{uuid}', s.id, wn.id, s.monthly_budget, s.currency, s.budget_mode, s.retirement_onboarding_dismissed, s.inserted_at, s.updated_at
      FROM settings s
      JOIN workspaces_new wn ON wn.legacy_id = s.workspace_id
      WHERE s.id = #{old_id}
      """
    end)

    copy_forward("sent_emails", fn old_id, uuid ->
      """
      INSERT INTO sent_emails_new (id, legacy_id, template, "to", subject, status, error, metadata, user_id, inserted_at)
      SELECT '#{uuid}', se.id, se.template, se."to", se.subject, se.status, se.error, se.metadata, un.id, se.inserted_at
      FROM sent_emails se
      LEFT JOIN users_new un ON un.legacy_id = se.user_id
      WHERE se.id = #{old_id}
      """
    end)

    copy_forward("debts", fn old_id, uuid ->
      """
      INSERT INTO debts_new
        (id, legacy_id, workspace_id, name, type, balance, apr, minimum_payment_floor,
         minimum_payment_rate, fixed_payment, credit_limit, exclude_from_plan,
         statement_balance, statement_date, status, paid_off_at, position,
         original_balance, due_day, auto_log_mode, last_due_handled_on, inserted_at, updated_at)
      SELECT '#{uuid}', d.id, wn.id, d.name, d.type, d.balance, d.apr, d.minimum_payment_floor,
             d.minimum_payment_rate, d.fixed_payment, d.credit_limit, d.exclude_from_plan,
             d.statement_balance, d.statement_date, d.status, d.paid_off_at, d.position,
             d.original_balance, d.due_day, d.auto_log_mode, d.last_due_handled_on, d.inserted_at, d.updated_at
      FROM debts d
      JOIN workspaces_new wn ON wn.legacy_id = d.workspace_id
      WHERE d.id = #{old_id}
      """
    end)

    copy_forward("payments", fn old_id, uuid ->
      """
      INSERT INTO payments_new (id, legacy_id, debt_id, amount, principal_portion, interest_portion, paid_on, logged_by_user_id, note, inserted_at, updated_at)
      SELECT '#{uuid}', p.id, dn.id, p.amount, p.principal_portion, p.interest_portion, p.paid_on, lun.id, p.note, p.inserted_at, p.updated_at
      FROM payments p
      JOIN debts_new dn ON dn.legacy_id = p.debt_id
      LEFT JOIN users_new lun ON lun.legacy_id = p.logged_by_user_id
      WHERE p.id = #{old_id}
      """
    end)

    copy_forward("activity_logs", fn old_id, uuid ->
      """
      INSERT INTO activity_logs_new (id, legacy_id, workspace_id, user_id, debt_id, action, metadata, inserted_at)
      SELECT '#{uuid}', al.id, wn.id, un.id, dn.id, al.action, al.metadata, al.inserted_at
      FROM activity_logs al
      JOIN workspaces_new wn ON wn.legacy_id = al.workspace_id
      LEFT JOIN users_new un ON un.legacy_id = al.user_id
      LEFT JOIN debts_new dn ON dn.legacy_id = al.debt_id
      WHERE al.id = #{old_id}
      """
    end)

    copy_forward("retirement_profiles", fn old_id, uuid ->
      """
      INSERT INTO retirement_profiles_new
        (id, legacy_id, workspace_id, user_id, name, claim_email, current_age, retirement_age,
         current_retirement_savings, monthly_retirement_contribution, monthly_gross_income,
         post_debt_investment_pct, expected_annual_return_pct, inserted_at, updated_at)
      SELECT '#{uuid}', rp.id, wn.id, un.id, rp.name, rp.claim_email, rp.current_age, rp.retirement_age,
             rp.current_retirement_savings, rp.monthly_retirement_contribution, rp.monthly_gross_income,
             rp.post_debt_investment_pct, rp.expected_annual_return_pct, rp.inserted_at, rp.updated_at
      FROM retirement_profiles rp
      JOIN workspaces_new wn ON wn.legacy_id = rp.workspace_id
      LEFT JOIN users_new un ON un.legacy_id = rp.user_id
      WHERE rp.id = #{old_id}
      """
    end)
  end

  defp copy_forward(old_table, insert_stmt_fn) do
    ids =
      repo().query!("SELECT id FROM #{old_table} ORDER BY id").rows
      |> List.flatten()

    for old_id <- ids do
      repo().query!(insert_stmt_fn.(old_id, Ecto.UUID.generate()))
    end
  end

  # ------------------------------------------------------------------
  # up/0 -- step 3: remap the integer ids embedded in sent_emails.metadata
  # to their new UUIDs (dropping the key if the referenced parent row no
  # longer exists, rather than leaving a stale integer behind).
  # ------------------------------------------------------------------

  defp remap_sent_emails_metadata_forward do
    rows = repo().query!("SELECT id, metadata FROM sent_emails_new").rows

    for [new_id, raw] <- rows do
      meta = decode_metadata(raw)

      remapped =
        Enum.reduce(@id_keys, meta, fn key, acc ->
          case Map.fetch(acc, key) do
            {:ok, v} when is_integer(v) ->
              table = Map.fetch!(@id_key_tables_new, key)

              case repo().query!("SELECT id FROM #{table} WHERE legacy_id = #{v}").rows do
                [[new_uuid]] -> Map.put(acc, key, new_uuid)
                [] -> Map.delete(acc, key)
              end

            _ ->
              acc
          end
        end)

      if remapped != meta, do: write_metadata("sent_emails_new", new_id, remapped)
    end
  end

  defp decode_metadata(nil), do: %{}
  defp decode_metadata(raw) when is_binary(raw), do: Jason.decode!(raw)
  defp decode_metadata(raw) when is_map(raw), do: raw

  defp write_metadata(table, id, map) do
    json = map |> Jason.encode!() |> String.replace("'", "''")
    repo().query!("UPDATE #{table} SET metadata = '#{json}' WHERE id = '#{id}'")
  end

  # ------------------------------------------------------------------
  # up/0 -- step 4: verify before dropping anything. A raise here rolls
  # back the whole transaction, so nothing is lost.
  # ------------------------------------------------------------------

  defp verify_before_cutover! do
    for table <- @final_tables do
      old_count = count!(table)
      new_count = count!("#{table}_new")

      if old_count != new_count do
        raise Ecto.MigrationError,
          message:
            "UUID migration aborted: #{table} had #{old_count} rows, #{table}_new has #{new_count}"
      end
    end

    for {table, column} <- @not_null_fks do
      unresolved = count_where_null!(table, column)

      if unresolved != 0 do
        raise Ecto.MigrationError,
          message:
            "UUID migration aborted: #{table}.#{column} has #{unresolved} unresolved NULL(s) after copy"
      end
    end

    for {old_table, old_column, new_table, new_column} <- @nullable_fks do
      old_non_null = count_where_not_null!(old_table, old_column)
      new_non_null = count_where_not_null!(new_table, new_column)

      if old_non_null != new_non_null do
        raise Ecto.MigrationError,
          message:
            "UUID migration aborted: #{old_table}.#{old_column} had #{old_non_null} non-null values, " <>
              "#{new_table}.#{new_column} has #{new_non_null}"
      end
    end
  end

  defp count!(table) do
    [[n]] = repo().query!("SELECT COUNT(*) FROM #{table}").rows
    n
  end

  defp count_where_null!(table, column) do
    [[n]] = repo().query!("SELECT COUNT(*) FROM #{table} WHERE #{column} IS NULL").rows
    n
  end

  defp count_where_not_null!(table, column) do
    [[n]] = repo().query!("SELECT COUNT(*) FROM #{table} WHERE #{column} IS NOT NULL").rows
    n
  end

  # ------------------------------------------------------------------
  # up/0 -- steps 5-7: drop the old tables (children before parents, so no
  # live ON DELETE CASCADE FK can cascade into surviving data), rename the
  # new tables into place, and recreate the app's indexes with their
  # original default-derived names.
  # ------------------------------------------------------------------

  defp drop_old_tables do
    drop table(:payments)
    drop table(:activity_logs)
    drop table(:retirement_profiles)
    drop table(:workspace_members)
    drop table(:workspace_invitations)
    drop table(:settings)
    drop table(:sent_emails)
    drop table(:debts)
    drop table(:workspaces)
    drop table(:users)
    drop table(:site_settings)
  end

  defp rename_new_tables do
    rename table(:users_new), to: table(:users)
    rename table(:workspaces_new), to: table(:workspaces)
    rename table(:site_settings_new), to: table(:site_settings)
    rename table(:workspace_members_new), to: table(:workspace_members)
    rename table(:workspace_invitations_new), to: table(:workspace_invitations)
    rename table(:settings_new), to: table(:settings)
    rename table(:sent_emails_new), to: table(:sent_emails)
    rename table(:debts_new), to: table(:debts)
    rename table(:payments_new), to: table(:payments)
    rename table(:activity_logs_new), to: table(:activity_logs)
    rename table(:retirement_profiles_new), to: table(:retirement_profiles)
  end

  defp create_indexes do
    create unique_index(:users, [:external_subject])

    create index(:workspaces, [:owner_user_id])

    create unique_index(:workspace_members, [:workspace_id, :user_id])
    create index(:workspace_members, [:user_id])

    create unique_index(:workspace_invitations, [:workspace_id, :email])
    create index(:workspace_invitations, [:email])

    create index(:debts, [:workspace_id])

    create index(:payments, [:debt_id])

    create unique_index(:settings, [:workspace_id])

    create index(:sent_emails, [:user_id])

    create index(:activity_logs, [:workspace_id])
    create index(:activity_logs, [:debt_id])

    create index(:retirement_profiles, [:workspace_id])

    # Left unnamed (default `<table>_<cols>_index`) -- see the comment in
    # priv/repo/migrations/20260919030000_create_retirement_profiles.exs on
    # why a custom name would silently break `unique_constraint/3` matching
    # on SQLite.
    create unique_index(:retirement_profiles, [:workspace_id, :user_id],
             where: "user_id IS NOT NULL"
           )

    create unique_index(:retirement_profiles, [:workspace_id, :claim_email],
             where: "claim_email IS NOT NULL"
           )
  end

  # ------------------------------------------------------------------
  # down/0 -- reversal. Only valid if every row still carries its original
  # legacy_id (i.e. nothing was created after the cutover).
  # ------------------------------------------------------------------

  defp guard_no_post_cutover_rows! do
    for table <- @final_tables do
      [[n]] = repo().query!("SELECT COUNT(*) FROM #{table} WHERE legacy_id IS NULL").rows

      if n != 0 do
        raise Ecto.MigrationError,
          message: """
          Cannot roll back: #{table} has #{n} row(s) created after the UUID \
          cutover, which have no original integer id to restore. Roll back \
          by restoring the pre-migration database backup instead.
          """
      end
    end
  end

  defp remap_sent_emails_metadata_backward do
    rows = repo().query!("SELECT id, metadata FROM sent_emails").rows

    for [id, raw] <- rows do
      meta = decode_metadata(raw)

      remapped =
        Enum.reduce(@id_keys, meta, fn key, acc ->
          case Map.fetch(acc, key) do
            {:ok, v} when is_binary(v) ->
              table = Map.fetch!(@id_key_tables_final, key)

              case repo().query!("SELECT legacy_id FROM #{table} WHERE id = '#{v}'").rows do
                [[legacy_id]] when not is_nil(legacy_id) -> Map.put(acc, key, legacy_id)
                _ -> Map.delete(acc, key)
              end

            _ ->
              acc
          end
        end)

      if remapped != meta, do: write_metadata("sent_emails", id, remapped)
    end
  end

  # Original integer-PK DDL, verbatim from the pre-migration schema (the 18
  # migrations this one supersedes), just suffixed "_old".
  defp create_old_tables do
    create table(:users_old) do
      add :external_subject, :string
      add :email, :string
      add :display_name, :string, null: false
      add :tutorial_seen, :boolean, null: false, default: false
      add :is_admin, :boolean, null: false, default: false
      timestamps()
    end

    create table(:workspaces_old) do
      add :name, :string, null: false
      add :owner_user_id, references(:users_old, on_delete: :delete_all), null: false
      timestamps()
    end

    create table(:site_settings_old) do
      add :site_name, :string
      add :from_name, :string
      add :from_email, :string
      add :welcome_emails_enabled, :boolean, null: false, default: true
      timestamps()
    end

    create table(:workspace_members_old) do
      add :workspace_id, references(:workspaces_old, on_delete: :delete_all), null: false
      add :user_id, references(:users_old, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "owner"
      timestamps()
    end

    create table(:workspace_invitations_old) do
      add :workspace_id, references(:workspaces_old, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :invited_by_user_id, references(:users_old, on_delete: :delete_all), null: false
      timestamps()
    end

    create table(:settings_old) do
      add :workspace_id, references(:workspaces_old, on_delete: :delete_all), null: false
      add :monthly_budget, :decimal
      add :currency, :string, null: false, default: "USD"
      add :budget_mode, :string, null: false, default: "total"
      add :retirement_onboarding_dismissed, :boolean, null: false, default: false
      timestamps()
    end

    create table(:sent_emails_old) do
      add :template, :string, null: false
      add :to, :string, null: false
      add :subject, :string, null: false
      add :status, :string, null: false
      add :error, :string
      add :metadata, :map, null: false, default: %{}
      add :user_id, references(:users_old, on_delete: :nilify_all)
      timestamps(updated_at: false)
    end

    create table(:debts_old) do
      add :workspace_id, references(:workspaces_old, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :type, :string, null: false
      add :balance, :decimal, null: false, default: 0
      add :apr, :decimal, null: false, default: 0
      add :minimum_payment_floor, :decimal
      add :minimum_payment_rate, :decimal
      add :fixed_payment, :decimal
      add :credit_limit, :decimal
      add :exclude_from_plan, :boolean, null: false, default: false
      add :statement_balance, :decimal
      add :statement_date, :date
      add :status, :string, null: false, default: "active"
      add :paid_off_at, :utc_datetime
      add :position, :integer, null: false, default: 0
      add :original_balance, :decimal
      add :due_day, :integer
      add :auto_log_mode, :string, null: false, default: "off"
      add :last_due_handled_on, :date
      timestamps()
    end

    create table(:payments_old) do
      add :debt_id, references(:debts_old, on_delete: :delete_all), null: false
      add :amount, :decimal, null: false
      add :principal_portion, :decimal
      add :interest_portion, :decimal
      add :paid_on, :date, null: false
      add :logged_by_user_id, references(:users_old, on_delete: :nilify_all)
      add :note, :string
      timestamps()
    end

    create table(:activity_logs_old) do
      add :workspace_id, references(:workspaces_old, on_delete: :delete_all), null: false
      add :user_id, references(:users_old, on_delete: :nilify_all)
      add :debt_id, references(:debts_old, on_delete: :nilify_all)
      add :action, :string, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(updated_at: false)
    end

    create table(:retirement_profiles_old) do
      add :workspace_id, references(:workspaces_old, on_delete: :delete_all), null: false
      add :user_id, references(:users_old, on_delete: :nilify_all)
      add :name, :string
      add :claim_email, :string
      add :current_age, :integer, null: false
      add :retirement_age, :integer, null: false
      add :current_retirement_savings, :decimal, null: false, default: 0
      add :monthly_retirement_contribution, :decimal, null: false, default: 0
      add :monthly_gross_income, :decimal, null: false, default: 0
      add :post_debt_investment_pct, :decimal, null: false, default: 15.0
      add :expected_annual_return_pct, :decimal, null: false, default: 7.0
      timestamps()
    end
  end

  # Copies from the current (UUID) tables back into the "_old" (integer PK)
  # tables, using each row's `legacy_id` as the restored `id`, and joining
  # the CURRENT tables (not "_old") to resolve each FK's `legacy_id` --
  # every row already carries its own `legacy_id`, so no extra lookup table
  # is needed beyond the current schema itself.
  defp copy_data_back do
    copy_back("users", fn old_id ->
      """
      INSERT INTO users_old (id, external_subject, email, display_name, tutorial_seen, is_admin, inserted_at, updated_at)
      SELECT u.legacy_id, u.external_subject, u.email, u.display_name, u.tutorial_seen, u.is_admin, u.inserted_at, u.updated_at
      FROM users u WHERE u.legacy_id = #{old_id}
      """
    end)

    copy_back("site_settings", fn old_id ->
      """
      INSERT INTO site_settings_old (id, site_name, from_name, from_email, welcome_emails_enabled, inserted_at, updated_at)
      SELECT ss.legacy_id, ss.site_name, ss.from_name, ss.from_email, ss.welcome_emails_enabled, ss.inserted_at, ss.updated_at
      FROM site_settings ss WHERE ss.legacy_id = #{old_id}
      """
    end)

    copy_back("workspaces", fn old_id ->
      """
      INSERT INTO workspaces_old (id, name, owner_user_id, inserted_at, updated_at)
      SELECT w.legacy_id, w.name, u.legacy_id, w.inserted_at, w.updated_at
      FROM workspaces w
      JOIN users u ON u.id = w.owner_user_id
      WHERE w.legacy_id = #{old_id}
      """
    end)

    copy_back("workspace_members", fn old_id ->
      """
      INSERT INTO workspace_members_old (id, workspace_id, user_id, role, inserted_at, updated_at)
      SELECT wm.legacy_id, w.legacy_id, u.legacy_id, wm.role, wm.inserted_at, wm.updated_at
      FROM workspace_members wm
      JOIN workspaces w ON w.id = wm.workspace_id
      JOIN users u ON u.id = wm.user_id
      WHERE wm.legacy_id = #{old_id}
      """
    end)

    copy_back("workspace_invitations", fn old_id ->
      """
      INSERT INTO workspace_invitations_old (id, workspace_id, email, invited_by_user_id, inserted_at, updated_at)
      SELECT wi.legacy_id, w.legacy_id, wi.email, iu.legacy_id, wi.inserted_at, wi.updated_at
      FROM workspace_invitations wi
      JOIN workspaces w ON w.id = wi.workspace_id
      JOIN users iu ON iu.id = wi.invited_by_user_id
      WHERE wi.legacy_id = #{old_id}
      """
    end)

    copy_back("settings", fn old_id ->
      """
      INSERT INTO settings_old (id, workspace_id, monthly_budget, currency, budget_mode, retirement_onboarding_dismissed, inserted_at, updated_at)
      SELECT s.legacy_id, w.legacy_id, s.monthly_budget, s.currency, s.budget_mode, s.retirement_onboarding_dismissed, s.inserted_at, s.updated_at
      FROM settings s
      JOIN workspaces w ON w.id = s.workspace_id
      WHERE s.legacy_id = #{old_id}
      """
    end)

    copy_back("sent_emails", fn old_id ->
      """
      INSERT INTO sent_emails_old (id, template, "to", subject, status, error, metadata, user_id, inserted_at)
      SELECT se.legacy_id, se.template, se."to", se.subject, se.status, se.error, se.metadata, u.legacy_id, se.inserted_at
      FROM sent_emails se
      LEFT JOIN users u ON u.id = se.user_id
      WHERE se.legacy_id = #{old_id}
      """
    end)

    copy_back("debts", fn old_id ->
      """
      INSERT INTO debts_old
        (id, workspace_id, name, type, balance, apr, minimum_payment_floor,
         minimum_payment_rate, fixed_payment, credit_limit, exclude_from_plan,
         statement_balance, statement_date, status, paid_off_at, position,
         original_balance, due_day, auto_log_mode, last_due_handled_on, inserted_at, updated_at)
      SELECT d.legacy_id, w.legacy_id, d.name, d.type, d.balance, d.apr, d.minimum_payment_floor,
             d.minimum_payment_rate, d.fixed_payment, d.credit_limit, d.exclude_from_plan,
             d.statement_balance, d.statement_date, d.status, d.paid_off_at, d.position,
             d.original_balance, d.due_day, d.auto_log_mode, d.last_due_handled_on, d.inserted_at, d.updated_at
      FROM debts d
      JOIN workspaces w ON w.id = d.workspace_id
      WHERE d.legacy_id = #{old_id}
      """
    end)

    copy_back("payments", fn old_id ->
      """
      INSERT INTO payments_old (id, debt_id, amount, principal_portion, interest_portion, paid_on, logged_by_user_id, note, inserted_at, updated_at)
      SELECT p.legacy_id, d.legacy_id, p.amount, p.principal_portion, p.interest_portion, p.paid_on, lu.legacy_id, p.note, p.inserted_at, p.updated_at
      FROM payments p
      JOIN debts d ON d.id = p.debt_id
      LEFT JOIN users lu ON lu.id = p.logged_by_user_id
      WHERE p.legacy_id = #{old_id}
      """
    end)

    copy_back("activity_logs", fn old_id ->
      """
      INSERT INTO activity_logs_old (id, workspace_id, user_id, debt_id, action, metadata, inserted_at)
      SELECT al.legacy_id, w.legacy_id, u.legacy_id, d.legacy_id, al.action, al.metadata, al.inserted_at
      FROM activity_logs al
      JOIN workspaces w ON w.id = al.workspace_id
      LEFT JOIN users u ON u.id = al.user_id
      LEFT JOIN debts d ON d.id = al.debt_id
      WHERE al.legacy_id = #{old_id}
      """
    end)

    copy_back("retirement_profiles", fn old_id ->
      """
      INSERT INTO retirement_profiles_old
        (id, workspace_id, user_id, name, claim_email, current_age, retirement_age,
         current_retirement_savings, monthly_retirement_contribution, monthly_gross_income,
         post_debt_investment_pct, expected_annual_return_pct, inserted_at, updated_at)
      SELECT rp.legacy_id, w.legacy_id, u.legacy_id, rp.name, rp.claim_email, rp.current_age, rp.retirement_age,
             rp.current_retirement_savings, rp.monthly_retirement_contribution, rp.monthly_gross_income,
             rp.post_debt_investment_pct, rp.expected_annual_return_pct, rp.inserted_at, rp.updated_at
      FROM retirement_profiles rp
      JOIN workspaces w ON w.id = rp.workspace_id
      LEFT JOIN users u ON u.id = rp.user_id
      WHERE rp.legacy_id = #{old_id}
      """
    end)
  end

  defp copy_back(current_table, insert_stmt_fn) do
    ids =
      repo().query!("SELECT legacy_id FROM #{current_table} ORDER BY legacy_id").rows
      |> List.flatten()

    for old_id <- ids do
      repo().query!(insert_stmt_fn.(old_id))
    end
  end

  defp verify_after_rollback! do
    for table <- @final_tables do
      current_count = count!(table)
      old_count = count!("#{table}_old")

      if current_count != old_count do
        raise Ecto.MigrationError,
          message:
            "UUID rollback aborted: #{table} has #{current_count} rows, #{table}_old has #{old_count}"
      end
    end
  end

  defp drop_uuid_tables do
    drop table(:payments)
    drop table(:activity_logs)
    drop table(:retirement_profiles)
    drop table(:workspace_members)
    drop table(:workspace_invitations)
    drop table(:settings)
    drop table(:sent_emails)
    drop table(:debts)
    drop table(:workspaces)
    drop table(:users)
    drop table(:site_settings)
  end

  defp rename_old_tables do
    rename table(:users_old), to: table(:users)
    rename table(:workspaces_old), to: table(:workspaces)
    rename table(:site_settings_old), to: table(:site_settings)
    rename table(:workspace_members_old), to: table(:workspace_members)
    rename table(:workspace_invitations_old), to: table(:workspace_invitations)
    rename table(:settings_old), to: table(:settings)
    rename table(:sent_emails_old), to: table(:sent_emails)
    rename table(:debts_old), to: table(:debts)
    rename table(:payments_old), to: table(:payments)
    rename table(:activity_logs_old), to: table(:activity_logs)
    rename table(:retirement_profiles_old), to: table(:retirement_profiles)
  end

  # SQLite's rowid allocation (with or without AUTOINCREMENT) tracks "the
  # largest ROWID this table has ever held" and self-corrects after an
  # explicit-id insert -- no manual reset needed there. Postgres `serial`/
  # `bigserial` columns use a SEQUENCE object that does NOT auto-track
  # explicit-id inserts, so without this the very next normal
  # `Repo.insert!` after a rollback could collide with a restored id.
  defp reset_autoincrement_counters do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      for table <- @final_tables do
        repo().query!("""
        SELECT setval(
          pg_get_serial_sequence('#{table}', 'id'),
          COALESCE((SELECT MAX(id) FROM #{table}), 1),
          (SELECT MAX(id) FROM #{table}) IS NOT NULL
        )
        """)
      end
    end
  end
end
