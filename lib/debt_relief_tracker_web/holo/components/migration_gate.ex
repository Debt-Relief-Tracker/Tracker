defmodule DebtReliefTrackerWeb.Holo.Components.MigrationGate do
  @moduledoc """
  Server side of the one-time plaintext -> vault migration
  (docs/architecture/0007-e2ee.md, "Migration server contract"). Thin
  commands over `DebtReliefTracker.E2EE.Migration`; the browser UI is wired
  later. Not yet mounted in `DashboardPage` (the integration step adds
  `<MigrationGate cid="migration_gate" />` next to `VaultGate`).

  Rules: the workspace and user come from `Holo.Context` (the session
  `Holo.Auth` resolved), NEVER params; owner-only checks live in the context;
  each command is rate limited per workspace through `E2EE.RateLimiter`
  (`:migration_status`/`:migration_dry_run` share the normal bucket;
  `:migration_export`/`:migration_finalize` use a strict one: burst 5, one
  token per 15 s); each returns exactly ONE page action. Nothing is logged;
  an unexpected exception is reported as `error: :failed` without its
  message (it could contain data).

  ## Commands -> page actions (`target: "page"`)

  Every reply is `%{op: <command>, ok: true, ...}` or
  `%{op: <command>, ok: false, error: <atom>}`; `error` may always be
  `:rate_limited`, `:invalid` (bad params) or `:failed` (unexpected).

    * `:migration_status` (no params) -> action `:migration_status_result`:
      `%{ok: true, status: :plaintext_only | :vault_only | :both | :empty,
      owner: boolean}`.
    * `:migration_export` (no params) -> `:migration_export_result`:
      `%{ok: true, snapshot: <Storage snapshot>, digest: string,
      members: [%{display_name, email}], pending_invitations: integer}`;
      errors `:forbidden | :already_encrypted | :nothing_to_migrate |
      :too_large`.
    * `:migration_dry_run` (no params) -> `:migration_dry_run_result`:
      `%{ok: true, counts: %{debts, payments, activity, retirement_profiles},
      members_to_remove: [%{display_name, email}], pending_invitations: n}`;
      error `:forbidden`.
    * `:migration_finalize` (`%{digest: string, confirm_remove_members:
      boolean}`) -> `:migration_finalize_result`: `%{ok: true, already_clean:
      true}` or `%{ok: true, deleted: %{debts, payments, activity,
      retirement_profiles}, removed_members: n, canceled_invitations: n}`;
      errors `:forbidden | :no_vault | :changed | :members_present`.
      Only the browser may send this, and only after it has re-downloaded
      and verified the vault.
  """

  use Hologram.Component

  require Logger

  alias DebtReliefTracker.Accounts
  alias DebtReliefTracker.E2EE.{Migration, RateLimiter}
  alias DebtReliefTrackerWeb.Holo.Context

  middleware DebtReliefTrackerWeb.Holo.Auth

  # Strict bucket for the two heavy / destructive commands.
  @strict [capacity: 5, refill_per_sec: 1 / 15]

  def template do
    ~HOLO"""
    <div id="migration-gate" class="hidden" aria-hidden="true"></div>
    """
  end

  # --- client actions: thin wrappers that issue the commands ----------------

  def action(:migration_status, _params, component), do: put_command(component, :migration_status)
  def action(:migration_export, _params, component), do: put_command(component, :migration_export)

  def action(:migration_dry_run, _params, component),
    do: put_command(component, :migration_dry_run)

  def action(:migration_finalize, %{digest: digest} = params, component),
    do:
      put_command(component, :migration_finalize,
        digest: digest,
        confirm_remove_members: Map.get(params, :confirm_remove_members) == true
      )

  # --- commands (server) ------------------------------------------------------

  def command(:migration_status, _params, server) do
    run(server, :migration_status, :normal, fn workspace, user ->
      %{ok: true, status: Migration.status(workspace), owner: owner?(workspace, user)}
    end)
  end

  def command(:migration_export, _params, server) do
    run(server, :migration_export, :strict, fn workspace, user ->
      case Migration.export(workspace, user) do
        {:ok, export} -> Map.put(export, :ok, true)
        {:error, reason} -> %{ok: false, error: reason}
      end
    end)
  end

  def command(:migration_dry_run, _params, server) do
    run(server, :migration_dry_run, :normal, fn workspace, user ->
      case Migration.dry_run(workspace, user) do
        {:ok, report} -> Map.put(report, :ok, true)
        {:error, reason} -> %{ok: false, error: reason}
      end
    end)
  end

  def command(:migration_finalize, %{digest: digest} = params, server) when is_binary(digest) do
    confirm? = Map.get(params, :confirm_remove_members) == true

    run(server, :migration_finalize, :strict, fn workspace, user ->
      case Migration.finalize(workspace, user, digest, confirm_remove_members: confirm?) do
        {:ok, :already_clean} -> %{ok: true, already_clean: true}
        {:ok, summary} -> Map.put(summary, :ok, true)
        {:error, reason} -> %{ok: false, error: reason}
      end
    end)
  end

  # Wrong shape from a crafted client: a plain error that echoes nothing.
  def command(op, _params, server) do
    reply(server, op, %{ok: false, error: :invalid})
  end

  # --- internals ----------------------------------------------------------

  defp run(server, op, bucket, fun) do
    workspace = Context.workspace(server)
    # No-auth mode: the implicit default user is the owner.
    user = Context.user(server) || Accounts.get_default_user!()

    result =
      case RateLimiter.check(key(bucket, workspace), limits(bucket)) do
        :ok -> guarded(fun, workspace, user)
        {:error, :rate_limited} -> %{ok: false, error: :rate_limited}
      end

    reply(server, op, result)
  end

  defp guarded(fun, workspace, user) do
    fun.(workspace, user)
  rescue
    # Never log the message: it may embed data.
    exception ->
      Logger.error("migration command failed: #{inspect(exception.__struct__)}")
      %{ok: false, error: :failed}
  end

  defp reply(server, op, result),
    do:
      put_action(server, name: result_name(op), target: "page", params: Map.put(result, :op, op))

  defp result_name(:migration_status), do: :migration_status_result
  defp result_name(:migration_export), do: :migration_export_result
  defp result_name(:migration_dry_run), do: :migration_dry_run_result
  defp result_name(:migration_finalize), do: :migration_finalize_result
  defp result_name(_unknown), do: :migration_error_result

  defp key(:normal, workspace), do: workspace.id
  defp key(:strict, workspace), do: {:migration, workspace.id}

  defp limits(:normal), do: []
  defp limits(:strict), do: @strict

  defp owner?(workspace, user), do: Accounts.owner?(workspace, user)
end
