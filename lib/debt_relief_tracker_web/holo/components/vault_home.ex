defmodule DebtReliefTrackerWeb.Holo.Components.VaultHome do
  @moduledoc """
  The E2EE bar above the dashboard (stateless): sync status, "Unlock
  methods", "Lock", the created / lock-blocked / remembered-device notices.
  The dashboard itself (header, sidebar, plan panel, modals) renders below it
  from `snapshot = VaultDoc.view(doc)`, exactly as in plaintext mode.

  Only when `config :debt_relief_tracker, :e2ee_test_hook` is on, it also
  shows a plain debt list with pay/delete buttons and a tiny add form that
  change the document through the ledger -- the hook the save/sync browser
  tests drive without the full UI.

  All events target the page (`VaultFlow`).
  """

  use Hologram.Component

  alias DebtReliefTrackerWeb.Holo.Format

  prop :snapshot, :map
  prop :vault, :map
  prop :sync, :map
  prop :account, :map

  def template do
    ~HOLO"""
    <div id="vault-home" class="flex flex-col gap-2 px-4 py-2 border-b border-base-300">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="text-sm font-medium">Encrypted vault</span>
        <div class="flex flex-wrap items-center gap-2">
          <span id="vault-sync-status" role="status" data-status={@sync.status} class={status_class(@sync.status)}>{status_text(@sync.status)}</span>
          {%if @sync.status == :failed}
            {%if @vault.sync_problem == :unreadable_server_copy}
              <span id="vault-sync-problem" class="text-xs text-warning">The server's copy could not be read. It may have been written by a newer version of the app, or it may be damaged. Your changes are kept on this device.</span>
            {/if}
            <button id="vault-sync-retry" type="button" class="btn btn-xs btn-outline" $click={action: :vault_retry, target: "page"}>Retry save</button>
          {/if}
          <button id="vault-methods-btn" type="button" class="btn btn-sm btn-ghost" $click={action: :open_modal, target: "page", params: %{modal: %{type: :vault_methods}}}>Unlock methods</button>
          <button id="vault-lock-btn" type="button" class="btn btn-sm btn-outline" $click={action: :vault_lock, target: "page"}>Lock</button>
        </div>
      </div>

      {%if @vault.notice == :created}
        <div id="vault-created-notice" role="status" class="alert alert-success flex flex-col sm:flex-row items-start sm:items-center gap-2">
          <span>Your encrypted vault is ready. You can add another unlock method, such as a passkey or a second passphrase, in Unlock methods.</span>
        </div>
      {/if}

      {%if not @vault.rollback_protection}
        <div id="vault-rollback-off" role="status" class="alert alert-warning">
          <span>Rollback protection is off in this browser (its local storage is unavailable), so an older copy of your vault from the server could not be detected.</span>
        </div>
      {/if}

      {%if @vault.lock_blocked}
        <div id="vault-lock-blocked" role="alert" class="alert alert-warning flex flex-col sm:flex-row items-start sm:items-center gap-2">
          <span>Your latest changes could not be saved, so the vault was not locked.</span>
          <button id="vault-lock-anyway" type="button" class="btn btn-xs btn-warning" $click={action: :vault_lock_anyway, target: "page"}>Lock anyway and discard them</button>
        </div>
      {/if}

      {%if @vault.device and not @vault.can_manage}
        <p id="vault-device-session" class="text-sm text-base-content/70">
          Opened with this remembered device. To add or remove unlock methods, lock and unlock with a passphrase, passkey or recovery key.
        </p>
      {/if}

      {%if @vault.test_hook}
        <section class="flex flex-col gap-2">
          <ul id="vault-debts" class="flex flex-col gap-2">
            {%for debt <- @snapshot.debts}
              <li id={"vault-debt-" <> debt.id} class="vault-debt flex flex-wrap items-center gap-2 border border-base-300 rounded p-2">
                <span class="vault-debt-name flex-1 font-medium break-words">{debt.name}</span>
                <span class="vault-debt-balance">{Format.money(debt.balance, @snapshot.settings.currency)}</span>
                <button id={"vault-pay-" <> debt.id} type="button" class="btn btn-xs btn-outline" $click={action: :vault_hook_pay, target: "page", params: %{id: debt.id}}>Pay $10</button>
                <button id={"vault-delete-" <> debt.id} type="button" class="btn btn-xs btn-ghost text-error" $click={action: :vault_hook_delete, target: "page", params: %{id: debt.id}}>Delete</button>
              </li>
            {/for}
          </ul>
          <p id="vault-payments-count" class="text-sm text-base-content/60">{length(@snapshot.payments)} payments</p>
          {%if @vault.perf}
            <p id="vault-perf" class="hidden" data-apply-ms={@vault.perf.apply_ms} data-view-ms={@vault.perf.view_ms}></p>
          {/if}
          <form id="test-hook-form" class="flex gap-2" $submit={action: :vault_hook_add, target: "page"}>
            <input id="test-hook-name" name="name" type="text" class="input input-sm flex-1" placeholder="Debt name" />
            <button id="test-hook-add" type="submit" class="btn btn-sm btn-outline">Add debt</button>
            <button id="test-hook-add-auto" type="button" class="btn btn-sm btn-outline" $click={action: :vault_hook_add_auto, target: "page"}>Add auto loan</button>
          </form>
        </section>
      {/if}
    </div>
    """
  end

  def status_text(:idle), do: "Up to date"
  def status_text(:dirty), do: "Unsaved changes"
  def status_text(:saving), do: "Saving..."
  def status_text(:saved), do: "Saved"
  def status_text(:merged), do: "Merged with changes from another device"
  def status_text(:offline), do: "Offline, will retry"
  def status_text(:failed), do: "Could not save your changes"
  def status_text(_), do: ""

  def status_class(:failed), do: "badge badge-error"
  def status_class(:offline), do: "badge badge-warning"
  def status_class(:saved), do: "badge badge-success"
  def status_class(_), do: "badge badge-ghost"
end
