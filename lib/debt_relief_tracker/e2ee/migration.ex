defmodule DebtReliefTracker.E2EE.Migration do
  @moduledoc """
  Server half of the one-time migration of a workspace's PLAINTEXT data into
  its end-to-end encrypted vault (docs/architecture/0007-e2ee.md, "Production
  rollout" and "Migration server contract").

  THIS MODULE DELETES USERS' DATA. Everything is therefore:

    * **Owner only.** The caller passes the `workspace` and `user` it derived
      server-side (`Holo.Context`); the owner is re-read from the database
      inside the transaction, never trusted from the struct.
    * **Vault first.** `finalize/4` refuses (`:no_vault`) unless an
      `e2ee_vaults` row exists for the workspace. The browser builds the vault
      from `export/2`, creates it, re-downloads and verifies it, and only then
      calls `finalize/4`.
    * **Vault-bound.** `finalize/4` also takes the `vault_rev` and
      `vault_blob_sha256` (lower hex SHA-256 of the blob string) of the vault
      the browser downloaded and verified, and re-checks both against the
      locked vault row before deleting (`:vault_changed` otherwise), so a
      vault overwritten, rebuilt or rolled back after verification can never
      authorise the deletion.
    * **Digest-guarded.** `export/2` returns a digest of the entire plaintext
      state; `finalize/4` recomputes it inside its transaction (after taking
      row locks) and refuses with `:changed` if anything differs, e.g. a
      payment posted between export and finalize.
    * **Atomic.** All deletes, the member removals and the invitation
      cancellations happen in ONE transaction; any failure rolls all of it
      back. Only THIS workspace's rows are touched.
    * **Explicit about other people.** If other members or pending invitations
      exist, `finalize/4` refuses (`:members_present`) unless
      `confirm_remove_members: true`; `dry_run/2` lists them first.

  ## Digest

  `digest/1` is `SHA-256` (lower hex) over a canonical, deterministic byte
  serialization (`canonical/1`) of:

      %{"v" => 1, "workspace_id", "snapshot" => Storage.Plain.load/1,
        "stamps" => id/inserted_at/updated_at of every plaintext row,
        "counts" => rows per table}

  The canonical form is a self-delimiting tagged encoding (type tag, length
  prefixes; map entries sorted by stringified key; collections of snapshot
  records sorted by `id`), so it does not depend on Jason, map ordering,
  query ordering or insertion order. Any added, removed or edited row (or
  settings / retirement change) changes it. Unknown term types raise rather
  than being silently dropped.

  ## Locking

    * PostgreSQL: `SET LOCAL lock_timeout`, then `SELECT ... FOR UPDATE` on the
      workspace row and every debt, payment, retirement-profile and settings
      row of the workspace BEFORE the digest is recomputed. `FOR UPDATE`
      conflicts with the `FOR KEY SHARE` locks that foreign-key checks take, so
      a concurrent payment / debt / activity insert for this workspace waits
      and then either sees the rows gone (its FK fails) or is serialized
      before our digest read. Two racing finalizes serialize on the workspace
      row; the loser finds nothing left (`:already_clean`).
    * SQLite: a no-op write on the workspace row first takes the database
      write lock (SQLite has a single writer), so the digest read and the
      deletes are one isolated unit.

  ## What it does not (and cannot) do

  After SQLite finalize a best-effort `VACUUM` + WAL truncate runs OUTSIDE the
  transaction to shrink the freed pages. On PostgreSQL nothing more is done:
  old backups, WAL archives and replicas still contain the plaintext until
  they age out. Nothing here is logged: no snapshot content reaches Logger and
  the queries that matter bind only ids.
  """

  import Ecto.Query

  require Logger

  alias DebtReliefTracker.Accounts.{User, Workspace, WorkspaceInvitation, WorkspaceMember}
  alias DebtReliefTracker.ActivityLog.Entry
  alias DebtReliefTracker.Debts.Debt
  alias DebtReliefTracker.E2EE.Vault
  alias DebtReliefTracker.Payments.Payment
  alias DebtReliefTracker.Repo
  alias DebtReliefTracker.Settings.{RetirementProfile, Setting}
  alias DebtReliefTracker.Storage.{Plain, Snapshot}

  @q [log: false]
  @digest_version 1
  @busy_codes [:deadlock_detected, :lock_not_available, :serialization_failure]

  @type status :: :plaintext_only | :vault_only | :both | :empty
  @type person :: %{display_name: String.t() | nil, email: String.t() | nil}

  # --- status ------------------------------------------------------------------

  @doc """
  `:plaintext_only` (plaintext rows, no vault), `:vault_only` (vault, no
  plaintext), `:both` (vault created, plaintext not yet finalized) or `:empty`.
  Plaintext = any debt, payment, activity entry, retirement profile, or a
  non-default settings value. Never decrypts anything.
  """
  @spec status(struct()) :: status()
  def status(%Workspace{id: ws}), do: combine(plaintext_counts?(ws), vault?(ws))

  @doc "`%{workspace_id => status}` for every workspace (set-based, no decryption)."
  @spec statuses() :: %{String.t() => status()}
  def statuses do
    plain = plaintext_workspace_ids()
    vaults = MapSet.new(Repo.all(from(v in Vault, select: v.workspace_id), @q))

    Map.new(Repo.all(from(w in Workspace, select: w.id), @q), fn id ->
      {id, combine(MapSet.member?(plain, id), MapSet.member?(vaults, id))}
    end)
  end

  @doc "How many workspaces are in each status (for the admin page); counts only."
  @spec status_counts() :: %{status() => non_neg_integer()}
  def status_counts, do: count_statuses(statuses())

  @doc "Tallies a `statuses/0` map into per-status counts."
  def count_statuses(statuses) do
    base = %{plaintext_only: 0, vault_only: 0, both: 0, empty: 0}
    statuses |> Map.values() |> Enum.reduce(base, &Map.update!(&2, &1, fn n -> n + 1 end))
  end

  @doc "Ids of workspaces that have a vault (the scheduler must not post into them)."
  @spec encrypted_workspace_ids() :: MapSet.t()
  def encrypted_workspace_ids,
    do: MapSet.new(Repo.all(from(v in Vault, select: v.workspace_id), @q))

  defp combine(true, false), do: :plaintext_only
  defp combine(false, true), do: :vault_only
  defp combine(true, true), do: :both
  defp combine(false, false), do: :empty

  defp vault?(ws), do: Repo.exists?(from(v in Vault, where: v.workspace_id == ^ws), @q)

  defp plaintext_counts?(ws) do
    Repo.exists?(from(d in Debt, where: d.workspace_id == ^ws), @q) or
      Repo.exists?(from(e in Entry, where: e.workspace_id == ^ws), @q) or
      Repo.exists?(from(r in RetirementProfile, where: r.workspace_id == ^ws), @q) or
      Repo.exists?(payments_in(ws), @q) or
      Repo.exists?(
        from(s in Setting, where: s.workspace_id == ^ws, where: ^non_default_settings()),
        @q
      )
  end

  defp plaintext_workspace_ids do
    [
      from(d in Debt, select: d.workspace_id),
      from(e in Entry, select: e.workspace_id),
      from(r in RetirementProfile, select: r.workspace_id),
      from(s in Setting, where: ^non_default_settings(), select: s.workspace_id)
    ]
    |> Enum.flat_map(&Repo.all(&1, @q))
    |> MapSet.new()
  end

  # Payments always belong to a debt of the workspace, so a workspace with
  # payments has debts; the separate payments check only guards against a
  # state where debts were removed but rows survived (it cannot, FK cascade).
  defp payments_in(ws) do
    from p in Payment, join: d in Debt, on: d.id == p.debt_id, where: d.workspace_id == ^ws
  end

  # The defaults a fresh settings row has (Setting schema + Settings context).
  defp non_default_settings do
    dynamic(
      [s],
      not is_nil(s.monthly_budget) or s.currency != "USD" or s.budget_mode != :total or
        s.retirement_onboarding_dismissed == true
    )
  end

  # --- export ------------------------------------------------------------------

  @doc """
  Everything the browser needs to build the vault: the plaintext `snapshot`
  (`Storage.Plain.load/1`), its `digest`, the other `members` who would lose
  access, and the number of `pending_invitations`. Owner only. Still allowed
  while a vault already exists but plaintext is left (`:both`), so the owner
  can re-export after a `:changed` refusal and merge the new data.
  """
  @spec export(struct(), struct() | nil) ::
          {:ok,
           %{
             snapshot: map(),
             digest: String.t(),
             members: [person()],
             pending_invitations: non_neg_integer()
           }}
          | {:error, :forbidden | :already_encrypted | :nothing_to_migrate | :too_large}
  def export(%Workspace{} = given, user) do
    with {:ok, %Workspace{id: ws} = workspace} <- authorize(given, user),
         :ok <- exportable(status(workspace)),
         :ok <- size_ok(ws),
         {:ok, snapshot} <- Plain.load(workspace) do
      {:ok,
       %{
         snapshot: snapshot,
         digest: digest(workspace, snapshot),
         members: people_to_remove(workspace),
         pending_invitations: pending_count(ws)
       }}
    end
  end

  defp exportable(:vault_only), do: {:error, :already_encrypted}
  defp exportable(:empty), do: {:error, :nothing_to_migrate}
  defp exportable(_), do: :ok

  # The snapshot caps activity at Snapshot.activity_limit/0 entries; refuse to
  # migrate (and so delete) more than the snapshot can carry.
  defp size_ok(ws) do
    n = Repo.aggregate(from(e in Entry, where: e.workspace_id == ^ws), :count, :id, @q)
    if n > Snapshot.activity_limit(), do: {:error, :too_large}, else: :ok
  end

  # --- dry run ------------------------------------------------------------------

  @doc "What `finalize/4` would delete and whom it would remove. Changes nothing."
  @spec dry_run(struct(), struct() | nil) ::
          {:ok,
           %{
             counts: %{
               debts: non_neg_integer(),
               payments: non_neg_integer(),
               activity: non_neg_integer(),
               retirement_profiles: non_neg_integer()
             },
             members_to_remove: [person()],
             pending_invitations: non_neg_integer()
           }}
          | {:error, :forbidden}
  def dry_run(%Workspace{} = given, user) do
    with {:ok, %Workspace{id: ws} = workspace} <- authorize(given, user) do
      {:ok,
       %{
         counts: row_counts(ws),
         members_to_remove: people_to_remove(workspace),
         pending_invitations: pending_count(ws)
       }}
    end
  end

  defp row_counts(ws) do
    %{
      debts: Repo.aggregate(from(d in Debt, where: d.workspace_id == ^ws), :count, :id, @q),
      payments: Repo.aggregate(payments_in(ws), :count, :id, @q),
      activity: Repo.aggregate(from(e in Entry, where: e.workspace_id == ^ws), :count, :id, @q),
      retirement_profiles:
        Repo.aggregate(
          from(r in RetirementProfile, where: r.workspace_id == ^ws),
          :count,
          :id,
          @q
        )
    }
  end

  defp people_to_remove(%Workspace{id: ws, owner_user_id: owner}) do
    from(m in WorkspaceMember,
      join: u in User,
      on: u.id == m.user_id,
      where: m.workspace_id == ^ws and m.user_id != ^owner,
      order_by: [asc: m.inserted_at, asc: m.id],
      select: %{display_name: u.display_name, email: u.email}
    )
    |> Repo.all(@q)
  end

  defp pending_count(ws),
    do:
      Repo.aggregate(
        from(i in WorkspaceInvitation, where: i.workspace_id == ^ws),
        :count,
        :id,
        @q
      )

  # --- finalize -----------------------------------------------------------------

  @doc """
  Deletes this workspace's plaintext, once, atomically. See the moduledoc.

  `{:error, :busy}` means a concurrent writer won a lock fight and everything
  rolled back; retry.

  Options: `:compact` (default `true`; SQLite VACUUM after commit, `false` skips it),
  `:confirm_remove_members` (must be exactly `true` when other
  members or pending invitations exist) and `:before_commit` (a 0-arity
  function run inside the transaction after all deletes, for tests to inject
  a failure; never set by the web layer).
  """
  @spec finalize(struct(), struct() | nil, String.t(), keyword()) ::
          {:ok,
           %{
             deleted: %{
               debts: non_neg_integer(),
               payments: non_neg_integer(),
               activity: non_neg_integer(),
               retirement_profiles: non_neg_integer()
             },
             removed_members: non_neg_integer(),
             canceled_invitations: non_neg_integer()
           }}
          | {:ok, :already_clean}
          | {:error,
             :forbidden | :no_vault | :changed | :vault_changed | :members_present | :busy}
  def finalize(%Workspace{} = workspace, user, digest, opts \\ []) do
    with {:ok, _} <- authorize(workspace, user) do
      result =
        Repo.transaction(fn -> locked_finalize(workspace.id, user, digest, opts) end, tx_opts())

      case result do
        {:ok, {:ok, %{} = summary}} ->
          if Keyword.get(opts, :compact, true), do: compact_sqlite()
          {:ok, summary}

        {:ok, other} ->
          other

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    # A concurrent writer won a lock fight (PostgreSQL deadlock victim /
    # lock_timeout, SQLite busy). The transaction has rolled back; nothing was
    # deleted. The caller may simply try again.
    e in Postgrex.Error ->
      if match?(%{code: code} when code in @busy_codes, e.postgres),
        do: {:error, :busy},
        else: reraise(e, __STACKTRACE__)

    e in Exqlite.Error ->
      if String.contains?(String.downcase(e.message), ["busy", "locked"]),
        do: {:error, :busy},
        else: reraise(e, __STACKTRACE__)
  end

  defp locked_finalize(ws_id, user, presented, opts) do
    workspace = lock_workspace(ws_id)

    cond do
      # Re-check ownership against the locked row, not the caller's struct.
      workspace == nil or workspace.owner_user_id != user.id ->
        Repo.rollback(:forbidden)

      not vault?(ws_id) ->
        Repo.rollback(:no_vault)

      not plaintext_counts?(ws_id) ->
        {:ok, :already_clean}

      true ->
        lock_rows(ws_id)
        verify_digest!(workspace, presented)
        verify_vault!(ws_id, opts)
        confirm_members!(workspace, opts)
        summary = delete_everything(workspace)
        if hook = opts[:before_commit], do: hook.()
        {:ok, summary}
    end
  end

  defp verify_digest!(workspace, presented) do
    with true <- is_binary(presented),
         {:ok, snapshot} <- Plain.load(workspace),
         actual = digest(workspace, snapshot),
         true <- Plug.Crypto.secure_compare(actual, presented) do
      :ok
    else
      _ -> Repo.rollback(:changed)
    end
  end

  # The vault must be the very one the browser verified: same rev and same
  # SHA-256 (lower hex) of the stored blob. Anything else (missing options
  # included) means it was overwritten, rebuilt or rolled back since: refuse,
  # nothing is deleted. The row is locked so it cannot move before commit.
  defp verify_vault!(ws_id, opts) do
    query =
      if postgres?(),
        do: from(v in Vault, where: v.workspace_id == ^ws_id, lock: "FOR UPDATE"),
        else: from(v in Vault, where: v.workspace_id == ^ws_id)

    rev = opts[:vault_rev]
    sha = opts[:vault_blob_sha256]

    with %Vault{} = vault <- Repo.one(query, @q),
         true <- is_integer(rev) and vault.rev == rev,
         true <- is_binary(sha) and is_binary(vault.blob),
         actual = Base.encode16(:crypto.hash(:sha256, vault.blob), case: :lower),
         true <- Plug.Crypto.secure_compare(actual, String.downcase(sha)) do
      :ok
    else
      _ -> Repo.rollback(:vault_changed)
    end
  end

  defp confirm_members!(workspace, opts) do
    others = people_to_remove(workspace) != [] or pending_count(workspace.id) > 0
    if others and opts[:confirm_remove_members] != true, do: Repo.rollback(:members_present)
    :ok
  end

  defp delete_everything(%Workspace{id: ws, owner_user_id: owner}) do
    {activity, _} = Repo.delete_all(from(e in Entry, where: e.workspace_id == ^ws), @q)

    debt_ids = from(d in Debt, where: d.workspace_id == ^ws, select: d.id)

    {payments, _} =
      Repo.delete_all(from(p in Payment, where: p.debt_id in subquery(debt_ids)), @q)

    {debts, _} = Repo.delete_all(from(d in Debt, where: d.workspace_id == ^ws), @q)

    {profiles, _} =
      Repo.delete_all(from(r in RetirementProfile, where: r.workspace_id == ^ws), @q)

    reset_settings(ws)

    {members, _} =
      Repo.delete_all(
        from(m in WorkspaceMember, where: m.workspace_id == ^ws and m.user_id != ^owner),
        @q
      )

    {invites, _} =
      Repo.delete_all(from(i in WorkspaceInvitation, where: i.workspace_id == ^ws), @q)

    %{
      deleted: %{
        debts: debts,
        payments: payments,
        activity: activity,
        retirement_profiles: profiles
      },
      removed_members: members,
      canceled_invitations: invites
    }
  end

  # Keeps the settings row shell; every value goes back to its default (they
  # now live in the vault).
  defp reset_settings(ws) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(s in Setting, where: s.workspace_id == ^ws),
      [
        set: [
          monthly_budget: nil,
          currency: "USD",
          budget_mode: :total,
          retirement_onboarding_dismissed: false,
          updated_at: now
        ]
      ],
      @q
    )
  end

  # --- locking ------------------------------------------------------------------

  defp sql!(statement),
    do: Ecto.Adapters.SQL.query!(Repo.active_repo(), statement, [], @q)

  # SQLite: BEGIN IMMEDIATE takes the single write lock up front (waiting via
  # busy_timeout) instead of failing later when a deferred read upgrades.
  defp tx_opts, do: if(postgres?(), do: @q, else: @q)

  defp postgres?, do: Repo.active_repo() == DebtReliefTracker.Repo.Postgres

  defp lock_workspace(ws_id) do
    if postgres?() do
      sql!("SET LOCAL lock_timeout = '10s'")

      Repo.one(from(w in Workspace, where: w.id == ^ws_id, lock: "FOR UPDATE"), @q)
    else
      # SQLite: a no-op write takes the single-writer lock for the whole tx.
      Repo.update_all(
        from(w in Workspace, where: w.id == ^ws_id, update: [set: [name: w.name]]),
        [],
        @q
      )

      Repo.get(Workspace, ws_id, @q)
    end
  end

  # Row locks on everything the digest covers, in a fixed order (workspace ->
  # debts -> payments -> profiles -> settings) so racing finalizes cannot
  # deadlock. SQLite already holds the write lock.
  defp lock_rows(ws_id) do
    if postgres?() do
      lock = fn query -> Repo.all(query, @q) end

      lock.(
        from(d in Debt,
          where: d.workspace_id == ^ws_id,
          order_by: d.id,
          select: d.id,
          lock: "FOR UPDATE"
        )
      )

      lock.(
        from(p in Payment,
          where:
            p.debt_id in subquery(from(d in Debt, where: d.workspace_id == ^ws_id, select: d.id)),
          order_by: p.id,
          select: p.id,
          lock: "FOR UPDATE"
        )
      )

      lock.(
        from(r in RetirementProfile,
          where: r.workspace_id == ^ws_id,
          order_by: r.id,
          select: r.id,
          lock: "FOR UPDATE"
        )
      )

      lock.(
        from(s in Setting,
          where: s.workspace_id == ^ws_id,
          order_by: s.id,
          select: s.id,
          lock: "FOR UPDATE"
        )
      )
    end

    :ok
  end

  # Best effort, never inside the transaction.
  defp compact_sqlite do
    if Repo.active_repo() == DebtReliefTracker.Repo.Sqlite do
      sql!("VACUUM")
      sql!("PRAGMA wal_checkpoint(TRUNCATE)")
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- authorization ------------------------------------------------------------

  # The owner is re-read from the database: a stale or forged struct cannot
  # grant access. Returns the fresh workspace.
  defp authorize(%Workspace{id: ws}, %User{id: uid}) do
    case Repo.get(Workspace, ws, @q) do
      %Workspace{owner_user_id: ^uid} = fresh -> {:ok, fresh}
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(_workspace, _user), do: {:error, :forbidden}

  # --- digest -------------------------------------------------------------------

  @doc """
  The digest of `workspace`'s current plaintext (see the moduledoc). Pass an
  already-loaded `snapshot` to avoid reading it twice.
  """
  @spec digest(struct(), map() | nil) :: String.t()
  def digest(%Workspace{id: ws}, snapshot \\ nil) do
    snapshot = snapshot || elem(Plain.load(%Workspace{id: ws}), 1)

    %{
      "v" => @digest_version,
      "workspace_id" => ws,
      "snapshot" => sort_collections(snapshot),
      "stamps" => stamps(ws),
      "counts" => row_counts(ws)
    }
    |> canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sort_collections(snapshot) do
    Map.new(snapshot, fn
      {key, [%{id: _} | _] = list} -> {key, Enum.sort_by(list, & &1.id)}
      other -> other
    end)
  end

  # id + timestamps of every plaintext row, including columns the snapshot
  # does not carry (debt inserted_at, settings row identity).
  defp stamps(ws) do
    iso = &iso/1

    %{
      "debts" =>
        from(d in Debt, where: d.workspace_id == ^ws, select: {d.id, d.inserted_at, d.updated_at})
        |> Repo.all(@q)
        |> Enum.map(fn {a, b, c} -> [a, iso.(b), iso.(c)] end),
      "payments" =>
        from(p in Payment,
          join: d in Debt,
          on: d.id == p.debt_id,
          where: d.workspace_id == ^ws,
          select: {p.id, p.debt_id, p.inserted_at, p.updated_at}
        )
        |> Repo.all(@q)
        |> Enum.map(fn {a, b, c, d} -> [a, b, iso.(c), iso.(d)] end),
      "activity" =>
        from(e in Entry, where: e.workspace_id == ^ws, select: {e.id, e.inserted_at})
        |> Repo.all(@q)
        |> Enum.map(fn {a, b} -> [a, iso.(b)] end),
      "retirement_profiles" =>
        from(r in RetirementProfile,
          where: r.workspace_id == ^ws,
          select: {r.id, r.inserted_at, r.updated_at}
        )
        |> Repo.all(@q)
        |> Enum.map(fn {a, b, c} -> [a, iso.(b), iso.(c)] end),
      "settings" =>
        from(s in Setting,
          where: s.workspace_id == ^ws,
          select: {s.id, s.inserted_at, s.updated_at}
        )
        |> Repo.all(@q)
        |> Enum.map(fn {a, b, c} -> [a, iso.(b), iso.(c)] end)
    }
    |> Map.new(fn {k, rows} -> {k, Enum.sort(rows)} end)
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  @doc """
  The canonical, self-delimiting serialization digested above. Tags: `n`
  nil, `t`/`f` booleans, `i<int>;` integers, `d<len>:<float>` floats,
  `s<bytes>:<data>` strings (atoms are strings), `l<count>:...` lists,
  `m<count>:<key><value>...` maps with entries sorted by string key.
  """
  @spec canonical(term()) :: binary()
  def canonical(term), do: term |> encode() |> IO.iodata_to_binary()

  defp encode(nil), do: "n"
  defp encode(true), do: "t"
  defp encode(false), do: "f"
  defp encode(int) when is_integer(int), do: ["i", Integer.to_string(int), ";"]

  defp encode(float) when is_float(float) do
    bin = :erlang.float_to_binary(float, [:short])
    ["d", Integer.to_string(byte_size(bin)), ":", bin]
  end

  defp encode(atom) when is_atom(atom), do: encode(Atom.to_string(atom))
  defp encode(bin) when is_binary(bin), do: ["s", Integer.to_string(byte_size(bin)), ":", bin]

  defp encode(list) when is_list(list),
    do: ["l", Integer.to_string(length(list)), ":" | Enum.map(list, &encode/1)]

  defp encode(%{__struct__: _} = struct),
    do: raise(ArgumentError, "cannot canonicalize struct #{inspect(struct.__struct__)}")

  defp encode(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn {k, v} -> {key_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))

    keys = Enum.map(entries, &elem(&1, 0))

    if keys != Enum.uniq(keys),
      do: raise(ArgumentError, "duplicate keys after stringification")

    [
      "m",
      Integer.to_string(length(entries)),
      ":" | Enum.map(entries, fn {k, v} -> [encode(k), encode(v)] end)
    ]
  end

  # Never `inspect/1` the term: it may be plaintext.
  defp encode(_other), do: raise(ArgumentError, "cannot canonicalize this term type")

  defp key_string(k) when is_binary(k), do: k
  defp key_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_string(k) when is_integer(k), do: Integer.to_string(k)
end
