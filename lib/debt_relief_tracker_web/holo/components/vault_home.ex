defmodule DebtReliefTrackerWeb.Holo.Components.VaultHome do
  @moduledoc """
  The unlocked E2EE screen (stateless): header with the sync status, "Unlock
  methods" and "Lock", a plain list of the decrypted debts, and -- only when
  `config :debt_relief_tracker, :e2ee_test_hook` is on -- a tiny form/buttons
  that change the document through the ledger (the minimal hook that proves
  the save/sync loop until the feature components route their saves through
  `Ledger`; roadmap Phase 8/10).

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
    <main id="vault-home" class="flex-1 flex flex-col gap-4 p-4 w-full max-w-3xl mx-auto">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
        <h1 class="text-2xl font-semibold">Debt Relief Tracker</h1>
        <div class="flex flex-wrap items-center gap-2">
          <span id="vault-sync-status" role="status" data-status={@sync.status} class={status_class(@sync.status)}>{status_text(@sync.status)}</span>
          {%if @sync.status == :failed}
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

      <section class="flex flex-col gap-2">
        <h2 class="font-semibold text-lg">Debts</h2>
        <p class="vault-debts-empty text-base-content/60 only:block hidden">No debts yet.</p>
        <ul id="vault-debts" class="flex flex-col gap-2">
          {%for debt <- @snapshot.debts}
            <li id={"vault-debt-" <> debt.id} class="vault-debt flex flex-wrap items-center gap-2 border border-base-300 rounded p-2">
              <span class="vault-debt-name flex-1 font-medium break-words">{debt.name}</span>
              <span class="vault-debt-balance">{Format.money(debt.balance, @snapshot.settings.currency)}</span>
              {%if @vault.test_hook}
                <button id={"vault-pay-" <> debt.id} type="button" class="btn btn-xs btn-outline" $click={action: :vault_hook_pay, target: "page", params: %{id: debt.id}}>Pay $10</button>
                <button id={"vault-delete-" <> debt.id} type="button" class="btn btn-xs btn-ghost text-error" $click={action: :vault_hook_delete, target: "page", params: %{id: debt.id}}>Delete</button>
              {/if}
            </li>
          {/for}
        </ul>
        <p id="vault-payments-count" class="text-sm text-base-content/60">{length(@snapshot.payments)} payments</p>
      </section>

      {%if @vault.test_hook}
        <form id="test-hook-form" class="flex gap-2" $submit={action: :vault_hook_add, target: "page"}>
          <input id="test-hook-name" name="name" type="text" class="input input-sm flex-1" placeholder="Debt name" />
          <button id="test-hook-add" type="submit" class="btn btn-sm btn-outline">Add debt</button>
          <button id="test-hook-add-auto" type="button" class="btn btn-sm btn-outline" $click={action: :vault_hook_add_auto, target: "page"}>Add auto loan</button>
        </form>
      {/if}

      <p class="text-xs text-base-content/50">
        Everything on this screen is decrypted in this browser. Editing screens for the encrypted vault are coming in a later release.
      </p>
    </main>
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
