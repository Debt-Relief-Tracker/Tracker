defmodule DebtReliefTrackerWeb.Holo.Components.MigrationScreen do
  @moduledoc """
  The visible part of the one-time plaintext -> encrypted migration (ADR 0007,
  "Production rollout"), shown by `DashboardPage` INSTEAD of the normal
  setup wizard when E2EE is on and the workspace still holds plaintext.

  It only drives `Holo.MigrationFlow` (pure) and performs the effects the
  flow emits: `MigrationGate` commands, the setup wizard (`VaultSetup`, given
  the vault document built from the export snapshot) and the verification
  download. `:migration_finalize` is only ever issued from the flow's
  `{:command, :migration_finalize, _}` effect, which the flow emits only after
  the re-downloaded vault matched the export.

  The page routes events here as `:migration_event`:
  `:vault_ready` (start, or the vault just got created), `:vault_failed`,
  `{:status_result | :export_result | :finalize_result, reply}` and
  `{:fetched, reply}` (the verification download).

  The `{:rebuild_vault, snapshot}` effect (after `:changed` or a verification
  mismatch) asks the page (`VaultFlow.migration_rebuild/2`) to CAS-save a new
  document over the existing vault; the page answers `:vault_ready` (saved,
  continue with the re-download) or `:vault_failed`.
  """

  use Hologram.Component

  alias DebtReliefTracker.{Crypto, VaultDoc}
  alias DebtReliefTrackerWeb.Holo.Components.VaultSetup
  alias DebtReliefTrackerWeb.Holo.MigrationFlow

  prop :vault, :map
  prop :account, :map

  def init(_props, component) do
    component
    |> put_state(:flow, MigrationFlow.new())
    |> put_state(:started, false)
    |> put_state(:doc, nil)
    |> put_state(:understood, false)
    |> put_state(:rebuild_needed, false)
  end

  def init(props, component, server), do: {init(props, component), server}

  def template do
    ~HOLO"""
    <section id="migration-screen" class="w-full max-w-lg flex flex-col gap-4 text-left" data-step={@flow.step}>
      <h1 class="text-xl sm:text-2xl font-semibold">Protect your data with end-to-end encryption</h1>

      {%if @flow.step == :checking}
        <p id="migration-checking" role="status" class="flex items-center gap-2">
          <span class="loading loading-spinner loading-sm"></span> Checking your data...
        </p>
      {/if}

      {%if @flow.step == :needs_migration}
        <p id="migration-intro">
          We've upgraded the app so that only you can read your finances. Setting this up takes a minute.
          Until you do, your existing data stays stored the way it is today and you can't use the app.
          Nothing is deleted until your encrypted copy is saved and checked.
        </p>
        <button id="migration-begin" type="button" class="btn btn-primary" $click={:begin}>Set up encryption</button>
      {/if}

      {%if @flow.step == :confirming_members}
        <div id="migration-members" role="alert" class="alert alert-warning flex flex-col items-start gap-2">
          <strong>Other people will lose access.</strong>
          <span>
            This workspace is shared. After you encrypt it, only you can open its data. They keep their own
            workspaces but will no longer see this one. Export your CSV first if they need a copy.
          </span>
          <ul id="migration-member-list" class="list-disc pl-5">
            {%for m <- @flow.export.members}
              <li>{m.display_name} ({m.email})</li>
            {/for}
          </ul>
          {%if @flow.export.pending_invitations > 0}
            <span id="migration-pending">Pending invitations will be canceled.</span>
          {/if}
        </div>
        <label class="flex items-start gap-2 text-sm">
          <input id="migration-understand" type="checkbox" class="checkbox checkbox-sm mt-0.5" checked={@understood} $change={:toggle_understood} />
          <span>I understand that the people listed above will lose access to this workspace's financial data.</span>
        </label>
        <button id="migration-confirm-members" type="button" class="btn btn-primary" disabled={not @understood} $click={:confirm_members}>
          Continue
        </button>
      {/if}

      {%if @flow.step == :setting_up}
        {%if @rebuild_needed}
          <p id="migration-rebuild" role="status" class="flex items-center gap-2">
            <span class="loading loading-spinner loading-sm"></span>
            Something changed, so we are updating your encrypted copy. Nothing has been deleted.
          </p>
        {%else}
          <VaultSetup cid="vault_setup" vault={@vault} account={@account} initial_doc={@doc} />
        {/if}
      {/if}

      {%if @flow.step in [:verifying, :finalizing, :re_exporting]}
        <ol id="migration-progress" class="steps steps-vertical" role="status">
          <li class="step step-primary">Exporting your data</li>
          <li class="step step-primary">Creating your encrypted vault</li>
          <li class={progress_class(@flow.step, :verifying)}>Checking the encrypted copy</li>
          <li class={progress_class(@flow.step, :finalizing)}>Deleting the old unencrypted copy</li>
          <li class="step">Done</li>
        </ol>
        <p class="flex items-center gap-2 text-sm">
          <span class="loading loading-spinner loading-sm"></span> Please keep this page open.
        </p>
      {/if}

      {%if @flow.step == :done}
        <p id="migration-done" role="status" class="alert alert-success">
          Your data is encrypted and your old unencrypted copy has been deleted from our database. Copies may
          remain in our hosting provider's backups until they expire.
        </p>
        <button id="migration-continue" type="button" class="btn btn-primary" $click={:finish}>
          Continue to my dashboard
        </button>
      {/if}

      {%if @flow.step == :failed}
        <p id="migration-error" role="alert" class="alert alert-error" data-reason={@flow.reason}>
          {error_text(@flow.reason)}
        </p>
        {%if can_retry?(@flow)}
          <button id="migration-retry" type="button" class="btn btn-primary" $click={:retry}>Try again</button>
        {/if}
        {%if @flow.reason == :verification_mismatch}
          <button id="migration-rebuild-btn" type="button" class="btn btn-outline" $click={:rebuild}>
            Rebuild the encrypted copy
          </button>
        {/if}
      {/if}
    </section>
    """
  end

  # --- template helpers -------------------------------------------------------

  def progress_class(step, step), do: "step step-primary"
  def progress_class(:finalizing, :verifying), do: "step step-primary"
  def progress_class(_current, _step), do: "step"

  def can_retry?(flow), do: not MigrationFlow.terminal?(flow) and flow.retry_effect != nil

  def error_text(:changed),
    do:
      "Something changed while we were encrypting your data, so we stopped before deleting anything. Please try again."

  def error_text(:busy),
    do: "The server is busy. Nothing was deleted. Please try again in a moment."

  def error_text(:verification_mismatch),
    do:
      "The encrypted copy did not match your data, so nothing was deleted. You can try again or rebuild the encrypted copy."

  def error_text(:vault_failed),
    do: "The encrypted vault could not be created. Nothing was deleted. Please try again."

  def error_text(:forbidden),
    do: "Only the workspace owner can encrypt this workspace. Nothing was deleted."

  def error_text(:too_large),
    do: "This workspace is too large to encrypt automatically. Nothing was deleted."

  def error_text(:members_present),
    do: "People joined this workspace during setup, so we stopped. Nothing was deleted."

  def error_text(:nothing_to_migrate), do: "There is nothing to encrypt."
  def error_text(:already_encrypted), do: "This workspace is already encrypted."

  def error_text(_other),
    do: "Something went wrong. Nothing was deleted. Please try again."

  # --- actions ------------------------------------------------------------------

  def action(:migration_event, %{event: :vault_ready}, component) do
    case component.state.flow.step do
      :checking ->
        if component.state.started do
          component
        else
          {flow, effects} = MigrationFlow.start(component.state.flow)

          component
          |> put_state(:started, true)
          |> put_state(:flow, flow)
          |> perform(effects)
        end

      :setting_up ->
        step(component, :vault_created)

      _ ->
        component
    end
  end

  # Resumed after a reload (status :both): the stored vault may be older than
  # the fresh export. The first mismatch is repaired by itself (rebuild once);
  # anything after that is shown to the user.
  def action(:migration_event, %{event: {:fetched, reply}}, component) do
    component = step(component, {:vault_downloaded, decode_download(reply, component.props)})
    flow = component.state.flow

    if flow.step == :failed and flow.reason == :verification_mismatch and flow.resume and
         flow.rebuilds == 0,
       do: step(component, :rebuild),
       else: component
  end

  def action(:migration_event, %{event: event}, component), do: step(component, event)

  def action(:begin, _params, component), do: step(component, :begin)
  def action(:retry, _params, component), do: step(component, :retry)
  def action(:rebuild, _params, component), do: step(component, :rebuild)

  def action(:toggle_understood, %{event: %{value: value}}, component),
    do: put_state(component, :understood, value == true or value == "true" or value == "on")

  def action(:confirm_members, _params, component) do
    if component.state.understood,
      do: step(component, {:confirm_members, true}),
      else: component
  end

  def action(:finish, _params, component),
    do: put_action(component, name: :migration_finished, target: "page")

  # A delayed re-send of an effect (busy backoff).
  def action(:run_effect, %{effect: effect}, component), do: perform(component, [effect])

  # --- internals -----------------------------------------------------------------

  defp step(component, event) do
    {flow, effects} = MigrationFlow.apply(component.state.flow, event)

    component
    |> put_state(:flow, flow)
    |> perform(effects)
  end

  # The flow emits at most one effect per transition.
  defp perform(component, []), do: component

  defp perform(component, [effect | _]), do: do_effect(component, effect)

  defp do_effect(component, {:command, :migration_status}),
    do: put_action(component, name: :migration_status, target: "migration_gate")

  defp do_effect(component, {:command, :migration_export}),
    do: put_action(component, name: :migration_export, target: "migration_gate")

  defp do_effect(component, {:command, :migration_finalize, params}),
    do: put_action(component, name: :migration_finalize, target: "migration_gate", params: params)

  defp do_effect(component, {:build_vault, snapshot}) do
    component
    |> put_state(:doc, VaultDoc.from_snapshot(snapshot))
    |> put_state(:rebuild_needed, false)
  end

  defp do_effect(component, {:rebuild_vault, snapshot}) do
    component
    |> put_state(:rebuild_needed, true)
    |> put_action(name: :migration_rebuild, target: "page", params: %{snapshot: snapshot})
  end

  defp do_effect(component, {:redownload_vault}),
    do: put_action(component, name: :migration_fetch, target: "page")

  defp do_effect(component, {:retry_after, delay, effect}),
    do: put_action(component, name: :run_effect, params: %{effect: effect}, delay: delay)

  # Re-downloaded blob -> decrypt -> decode -> view (what `verify/2` compares).
  defp decode_download(%{ok: true, exists: true, rev: rev, blob: blob}, props) do
    ws = props.account.workspace.id

    with {:ok, text} <- Crypto.decrypt_document(props.vault.handle, ws, rev, blob),
         {:ok, doc} <- VaultDoc.decode(text) do
      {:ok, VaultDoc.view(doc)}
    else
      _ -> {:error, :undecryptable}
    end
  end

  defp decode_download(_reply, _props), do: {:error, :fetch_failed}
end
