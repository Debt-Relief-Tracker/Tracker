defmodule DebtReliefTrackerWeb.Holo.DashboardPage do
  @moduledoc """
  The Hologram dashboard (docs/architecture/0007-e2ee.md, roadmap Phase 10).
  Served at `/app` alongside the LiveView at `/` until it reaches parity.

  This page only owns shared state and layout; every feature lives in a
  component under `Holo.Components.*` (see docs/holo-ui-conventions.md):

    * `:e2ee` -- true in E2EE mode: the server never loads financial data, so
      `:snapshot` is `nil` and the page renders only a locked shell.
    * `:vault` -- E2EE only: the client-side vault state machine
      (`Holo.VaultFlow`: phase `:no_vault | :locked | :unlocked`, the
      server-visible key wraps, an opaque crypto session handle -- never a
      key, the blob or plaintext).
    * `:doc` / `:sync` -- E2EE only, memory only, `nil` while locked: the
      decrypted `VaultDoc` and the save-loop state.
    * `:snapshot` -- a `Storage` snapshot, the single source of truth for all
      financial data. Everything displayed is derived from it by the shared
      integer engine.
    * `:account` -- plain account/session data (user, workspace, OIDC flag).
    * `:modal` -- `nil` or `%{type: atom, ...}`; at most one modal is open.
    * `:strategy` -- the selected payoff strategy.
  """

  use Hologram.Page

  alias DebtReliefTrackerWeb.Holo.Components.ActivityLogModal
  alias DebtReliefTrackerWeb.Holo.Components.DebtFormModal
  alias DebtReliefTrackerWeb.Holo.Components.DebtSidebar
  alias DebtReliefTrackerWeb.Holo.Components.Footer
  alias DebtReliefTrackerWeb.Holo.Components.HeaderBar
  alias DebtReliefTrackerWeb.Holo.Components.LogAllBalancesModal
  alias DebtReliefTrackerWeb.Holo.Components.PaymentModal
  alias DebtReliefTrackerWeb.Holo.Components.PlanPanel
  alias DebtReliefTrackerWeb.Holo.Components.RetirementBanner
  alias DebtReliefTrackerWeb.Holo.Components.RetirementModal
  alias DebtReliefTrackerWeb.Holo.Components.SettingsModal
  alias DebtReliefTrackerWeb.Holo.Components.TutorialOverlay
  alias DebtReliefTrackerWeb.Holo.Components.VaultGate
  alias DebtReliefTrackerWeb.Holo.Components.VaultHome
  alias DebtReliefTrackerWeb.Holo.Components.VaultMethods
  alias DebtReliefTrackerWeb.Holo.Components.VaultSetup
  alias DebtReliefTrackerWeb.Holo.Components.VaultUnlock
  alias DebtReliefTracker.E2EE
  alias DebtReliefTracker.E2EE.Vaults
  alias DebtReliefTrackerWeb.Holo.Context
  alias DebtReliefTrackerWeb.Holo.VaultFlow

  route "/app"
  layout DebtReliefTrackerWeb.Holo.Layout

  middleware DebtReliefTrackerWeb.Holo.Auth

  # Server, first render. In E2EE mode this renders a locked shell and never
  # touches plaintext: no snapshot is loaded (Storage.Vault could not anyway),
  # only whether a vault exists.
  def init(_params, component, server) do
    if E2EE.enabled?() do
      workspace = Context.workspace(server)
      wraps = for w <- Vaults.key_wraps(workspace), do: VaultGate.wrap_view(w)

      vault =
        VaultFlow.new_vault(wraps,
          idle_ms: Application.get_env(:debt_relief_tracker, :e2ee_idle_ms, 900_000),
          test_hook: Application.get_env(:debt_relief_tracker, :e2ee_test_hook, false)
        )

      component
      |> put_context(:e2ee, true)
      |> put_state(:e2ee, true)
      |> put_state(:vault, vault)
      |> put_state(:vault_result, nil)
      |> put_state(:snapshot, nil)
      |> put_state(:doc, nil)
      |> put_state(:sync, nil)
      |> put_state(:account, Context.account(server))
      |> put_state(:strategy, :cash_flow)
      |> put_state(:modal, nil)
      |> put_state(:error, nil)
      |> put_state(:notice, nil)
      # Client-side on mount: environment, feature detection, remembered device.
      |> put_action(:vault_boot)
    else
      {:ok, snapshot} = Context.load(server)

      component
      |> put_context(:e2ee, false)
      |> put_state(:e2ee, false)
      |> put_state(:vault, nil)
      |> put_state(:vault_result, nil)
      |> put_state(:doc, nil)
      |> put_state(:sync, nil)
      |> put_state(:snapshot, snapshot)
      |> put_state(:account, Context.account(server))
      |> put_state(:strategy, :cash_flow)
      |> put_state(:modal, nil)
      |> put_state(:error, nil)
      |> put_state(:notice, nil)
    end
  end

  def template do
    ~HOLO"""
    <div id="holo-dashboard" class="flex flex-col min-h-screen">
      {%if @e2ee and @vault.rollback}
        <main id="e2ee-locked" class="flex-1 flex flex-col items-center justify-center gap-4 p-6 text-center">
          <h1 class="text-2xl font-semibold">Debt Relief Tracker</h1>
          <div id="vault-rollback" role="alert" class="alert alert-warning max-w-lg flex flex-col gap-2 text-left">
            <strong>Your vault may have been rolled back or tampered with.</strong>
            <span>
              The server returned an older version of your encrypted data than this browser has seen before, or a
              different one with the same version number. This can happen after a restore from backup, but it can
              also mean someone is replaying old data. Continue only if you expect this.
            </span>
            <div class="flex flex-wrap gap-2">
              <button id="vault-rollback-ack" type="button" class="btn btn-sm btn-warning" $click={:vault_rollback_ack}>I understand, continue</button>
              <button id="vault-rollback-lock" type="button" class="btn btn-sm btn-outline" $click={:vault_lock}>Lock</button>
            </div>
          </div>
        </main>
      {%else}
        {%if @e2ee and @vault.phase != :unlocked}
          <main id="e2ee-locked" class="flex-1 flex flex-col items-center justify-center gap-4 p-6 text-center">
            <h1 class="text-2xl font-semibold">Debt Relief Tracker</h1>
            <p id="e2ee-locked-status" class="text-base-content/70 max-w-md">
              {%if @vault.phase == :locked}
                Your encrypted vault is locked. Unlocking happens in this browser; the server never sees your data.
              {%else}
                End-to-end encryption is on, but no vault has been created yet.
              {/if}
            </p>
            {%if @vault.phase == :locked}
              <VaultUnlock cid="vault_unlock" vault={@vault} account={@account} />
            {%else}
              <VaultSetup cid="vault_setup" vault={@vault} account={@account} />
            {/if}
          </main>
        {%else}
          {%if @e2ee}
            <VaultHome snapshot={@snapshot} vault={@vault} sync={@sync} account={@account} />
          {/if}

          <HeaderBar cid="header_bar" snapshot={@snapshot} account={@account} />

          <div class="flex flex-col sm:flex-row flex-1 min-h-0">
            <aside class="w-full sm:w-1/5 sm:min-w-[220px] border-b sm:border-b-0 sm:border-r border-base-300 p-3 flex flex-col gap-3 min-h-0">
              <DebtSidebar cid="debt_sidebar" snapshot={@snapshot} account={@account} />
            </aside>

            <main class="flex-1 p-4 min-w-0 flex flex-col gap-4">
              <RetirementBanner cid="retirement_banner" snapshot={@snapshot} />
              <PlanPanel cid="plan_panel" snapshot={@snapshot} account={@account} strategy={@strategy} />
            </main>
          </div>

          {%if @notice}
            <div id="page-notice" role="status" class="toast toast-top toast-end z-50">
              <div class="alert alert-info">
                <span id="page-notice-text">{@notice}</span>
                <button id="page-notice-dismiss" type="button" class="btn btn-ghost btn-xs" aria-label="Dismiss" $click={:dismiss_notice}>
                  <span class="hero-x-mark w-4 h-4"></span>
                </button>
              </div>
            </div>
          {/if}

          <TutorialOverlay cid="tutorial_overlay" snapshot={@snapshot} account={@account} />

          {%if @modal}
            {%if @modal.type == :add_debt || @modal.type == :edit_debt}
              <DebtFormModal cid="debt_form_modal" snapshot={@snapshot} account={@account} modal={@modal} />
            {/if}
            {%if @modal.type == :log_payment}
              <PaymentModal cid="payment_modal" snapshot={@snapshot} account={@account} modal={@modal} />
            {/if}
            {%if @modal.type == :log_all_balances}
              <LogAllBalancesModal cid="log_all_balances_modal" snapshot={@snapshot} account={@account} modal={@modal} />
            {/if}
            {%if @modal.type == :activity_log}
              <ActivityLogModal cid="activity_log_modal" snapshot={@snapshot} account={@account} modal={@modal} />
            {/if}
            {%if @modal.type == :settings}
              <SettingsModal cid="settings_modal" snapshot={@snapshot} account={@account} modal={@modal} />
            {/if}
            {%if @modal.type == :retirement_onboarding || @modal.type == :retirement_profile_form}
              <RetirementModal cid="retirement_modal" snapshot={@snapshot} account={@account} modal={@modal} />
            {/if}
          {/if}
        {/if}
      {/if}

      {%if @e2ee}
        <VaultGate cid="vault_gate" />
        {%if @modal}
          {%if @modal.type == :vault_methods}
            <VaultMethods cid="vault_methods" vault={@vault} account={@account} />
          {/if}
        {/if}
      {/if}
      <Footer cid="footer" account={@account} />
    </div>
    """
  end

  # --- shared actions (children target these with `target: "page"`) -------

  # A child (or a command's reply) delivers a fresh snapshot.
  # Pass `close_modal: true` to also close the open modal -- a handler can
  # queue only ONE follow-up action (a second `put_action` overwrites the
  # first), so "update the snapshot and close" has to be a single action.
  # Its one follow-up tells the plan panel to recompute its derived numbers
  # and JS-drawn chart (it runs after this render, so it reads new props).
  def action(:snapshot_updated, %{snapshot: snapshot} = params, component) do
    component
    |> put_state(:snapshot, snapshot)
    |> put_state(:error, nil)
    |> put_state(:modal, if(Map.get(params, :close_modal), do: nil, else: component.state.modal))
    # `delay` lets the browser paint (modal closed, new snapshot) first: the
    # plan recompute runs the payoff simulation in JS for several seconds and
    # an un-delayed chained action would hold that paint back until it ends.
    |> put_action(name: :plan_inputs_changed, target: "plan_panel", delay: 50)
  end

  def action(:change_failed, %{error: error}, component), do: put_state(component, :error, error)

  def action(:account_updated, %{account: account}, component),
    do: put_state(component, :account, account)

  # Account-level changes (settings saved, workspace switched, sharing
  # changed) update account, snapshot and modal in one step: a command can
  # return only ONE next action, so these can't be chained.
  def action(
        :account_changed,
        %{account: account, snapshot: snapshot, modal: modal} = params,
        component
      ) do
    component
    |> put_state(:account, account)
    |> put_state(:snapshot, snapshot)
    |> put_state(:modal, modal)
    |> put_state(:error, nil)
    |> put_state(:notice, Map.get(params, :notice))
  end

  # --- E2EE mode: delegated to Holo.VaultFlow (see its moduledoc) --------------

  def action(:vault_boot, _params, component), do: VaultFlow.boot(component)
  def action(:vault_result, params, component), do: VaultFlow.result(component, params)
  def action(:vault_opened, params, component), do: VaultFlow.opened(component, params)

  def action(:vault_create_request, params, component),
    do: VaultFlow.create_request(component, params)

  def action(:vault_rollback_ack, _params, component), do: VaultFlow.rollback_ack(component)
  def action(:vault_lock, _params, component), do: VaultFlow.request_lock(component, :manual)
  def action(:vault_lock_anyway, _params, component), do: VaultFlow.lock_anyway(component)
  def action(:vault_retry, _params, component), do: VaultFlow.retry(component)
  def action(:vault_flush, params, component), do: VaultFlow.flush(component, params)
  def action(:vault_methods_op, params, component), do: VaultFlow.methods_op(component, params)

  def action(:vault_session_event, params, component),
    do: VaultFlow.session_event(component, params)

  def action(:vault_apply_change, %{change: change}, component),
    do: VaultFlow.apply_change(component, change)

  # A feature component's change (`Holo.DataPath.save/4`): ledger + encrypted save + reply.
  def action(:vault_apply_request, request, component),
    do: VaultFlow.apply_request(component, request)

  # Minimal editing hook (test_hook config) until feature components use the ledger.
  def action(:vault_hook_add, %{event: %{"name" => name}}, component) when name != "",
    do: VaultFlow.test_hook_add(component, name)

  def action(:vault_hook_add, _params, component), do: component

  def action(:vault_hook_add_auto, _params, component),
    do: VaultFlow.test_hook_add_auto(component)

  def action(:vault_hook_pay, %{id: id}, component), do: VaultFlow.test_hook_pay(component, id)

  def action(:vault_hook_delete, %{id: id}, component),
    do: VaultFlow.test_hook_delete(component, id)

  def action(:dismiss_notice, _params, component), do: put_state(component, :notice, nil)

  def action(:open_modal, %{modal: modal}, component) do
    component |> put_state(:modal, modal) |> put_state(:notice, nil)
  end

  def action(:close_modal, _params, component), do: put_state(component, :modal, nil)

  # Settings modal's "View tutorial again": close the modal and hand off to
  # the tutorial overlay (which resets tutorial_seen and starts at step 1).
  def action(:restart_tutorial, _params, component) do
    component
    |> put_state(:modal, nil)
    |> put_action(name: :restart, target: "tutorial_overlay")
  end

  def action(:select_strategy, %{strategy: strategy}, component) do
    component
    |> put_state(:strategy, strategy)
    |> put_action(name: :plan_inputs_changed, target: "plan_panel")
  end
end
