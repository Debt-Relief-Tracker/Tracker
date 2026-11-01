defmodule DebtReliefTracker.E2EE.PlainGuard do
  @moduledoc """
  Keeps plaintext writes out of a workspace that has an end-to-end encrypted
  vault (docs/architecture/0007-e2ee.md, "Migration server contract").

  `E2EE.Migration.finalize/4` deletes the workspace's plaintext rows under
  locks. Without this guard, a plaintext write (`Storage.Plain`, the LiveView
  at `/`, the scheduler) that races it could re-create plaintext rows after
  the commit. Every plaintext write path in the contexts runs inside
  `transaction/2`, which, in the same transaction as the write:

    * PostgreSQL: takes `SELECT ... FOR SHARE` on the workspace row. That
      conflicts with finalize's `FOR UPDATE`, so the write either waits for
      finalize to commit (then sees the vault and refuses) or finalize waits
      for the write to commit (then its digest covers the new row and it
      answers `:changed`). Concurrent plaintext writers do not block each
      other.
    * SQLite: does a no-op write on the workspace row first, which takes the
      single write lock for the whole transaction (the same trick finalize
      uses), so the check and the write are atomic w.r.t. finalize.

  then refuses with `{:error, :workspace_encrypted}` if an `e2ee_vaults` row
  exists. No schema change; the vault row is the single source of truth.

  Not covered on purpose: creating the default (empty) settings row in
  `Settings.get_settings!/1`, which carries no financial data.
  """

  import Ecto.Query

  alias DebtReliefTracker.Accounts.Workspace
  alias DebtReliefTracker.E2EE.Vault
  alias DebtReliefTracker.Repo

  @q [log: false]

  @doc """
  Runs `fun` (returning `{:ok, value}` or `{:error, reason}`, like the context
  functions) in a transaction after locking and checking the workspace.
  Returns `{:ok, value}`, `{:error, reason}` (rolled back) or
  `{:error, :workspace_encrypted}`. Joins an enclosing transaction.
  """
  @spec transaction(Ecto.UUID.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def transaction(workspace_id, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      lock_and_check!(workspace_id)

      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_and_check!(workspace_id) do
    if Repo.active_repo() == DebtReliefTracker.Repo.Postgres do
      Repo.one(
        from(w in Workspace, where: w.id == ^workspace_id, lock: "FOR SHARE", select: w.id),
        @q
      )
    else
      Repo.update_all(
        from(w in Workspace, where: w.id == ^workspace_id, update: [set: [name: w.name]]),
        [],
        @q
      )
    end

    # A fresh statement: under READ COMMITTED it sees a vault committed while
    # we waited for the lock.
    if Repo.exists?(from(v in Vault, where: v.workspace_id == ^workspace_id), @q),
      do: Repo.rollback(:workspace_encrypted)

    :ok
  end
end
