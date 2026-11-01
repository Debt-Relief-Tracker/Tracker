defmodule DebtReliefTrackerWeb.Holo.Components.VaultSetup do
  @moduledoc """
  The E2EE setup wizard (ADR 0007, "Setup wizard"): shown when the workspace
  has no vault. All key work happens in the browser through the opaque-handle
  `Crypto` facade; this component never holds a key, only a handle.

    1. **Choose** a method: a passkey (only when the browser reports WebAuthn
       PRF support) or a passphrase (min 12 characters, strength meter,
       confirmation, an honest offline-guessing warning).
    2. **Recovery key**: generate the vault key, wrap it under the chosen
       method AND a recovery key; show the recovery key ONCE and require
       acknowledgment (a checkbox and the final group typed back).
    3. **Create**: encrypt the first document (revision 1) and hand everything
       to the page (`:vault_create_request`), which calls the server command.

  The first document is `VaultDoc.new()` unless the `initial_doc` prop carries
  one (Phase 9: the plaintext -> vault migration builds it with
  `VaultDoc.from_snapshot/2`).

  Local state is ephemeral UI state; the recovery key text lives here only
  until the wizard hands off and is then dropped.
  """

  use Hologram.Component

  alias DebtReliefTracker.{Crypto, VaultDoc, VaultEnv}
  alias DebtReliefTracker.VaultClient.{Recovery, Strength}

  prop :vault, :map
  prop :account, :map
  prop :initial_doc, :map, default: nil

  def init(props, component) do
    put_state(component,
      step: :choose,
      method: if(props.vault.prf, do: :passkey, else: :passphrase),
      passphrase: "",
      confirm: "",
      strength: Strength.estimate(""),
      remember: false,
      error: nil,
      handle: nil,
      wraps: [],
      recovery_key: nil,
      ack_saved: false,
      ack_final: "",
      copied: false
    )
  end

  def init(props, component, server), do: {init(props, component), server}

  def template do
    ~HOLO"""
    <section id="vault-setup" class="w-full max-w-lg flex flex-col gap-4 text-left">
      <h2 class="text-xl font-semibold">Set up your encrypted vault</h2>

      {%if @step == :choose}
        <p class="text-base-content/70">
          Your data is encrypted in this browser before it is saved. The server only ever stores ciphertext
          and never sees your passphrase, keys or financial data.
        </p>

        <div class="flex flex-col sm:flex-row gap-2" role="group" aria-label="Unlock method">
          {%if @vault.prf}
            <button id="setup-method-passkey" type="button" class={method_class(@method == :passkey)} $click={:set_method, method: :passkey}>
              Passkey
            </button>
          {/if}
          <button id="setup-method-passphrase" type="button" class={method_class(@method == :passphrase)} $click={:set_method, method: :passphrase}>
            Passphrase
          </button>
        </div>

        {%if @method == :passphrase}
          <form id="setup-passphrase-form" class="flex flex-col gap-3" $submit="continue">
            <label class="flex flex-col gap-1">
              <span class="text-sm font-medium">Passphrase (at least 12 characters)</span>
              <input id="setup-passphrase" type="password" autocomplete="new-password" class="input w-full" value={@passphrase} $change={:set_field, field: :passphrase} />
            </label>
            <div class="flex items-center gap-2" aria-live="polite">
              <progress id="setup-strength" class="progress w-40" value={@strength.level} max="4"></progress>
              <span id="setup-strength-label" class="text-sm">{@strength.label}</span>
            </div>
            <label class="flex flex-col gap-1">
              <span class="text-sm font-medium">Confirm passphrase</span>
              <input id="setup-confirm" type="password" autocomplete="new-password" class="input w-full" value={@confirm} $change={:set_field, field: :confirm} />
            </label>
            <p id="setup-offline-warning" class="text-sm text-warning">
              Anyone who gets a copy of the database can try passphrases offline, as fast as their hardware allows.
              Only a long, unusual passphrase keeps your data safe in that case; a passphrase manager or a few
              unrelated words work well. Nobody, including us, can reset it for you.
            </p>
            <label class="flex items-start gap-2 text-sm">
              <input id="setup-remember" type="checkbox" class="checkbox checkbox-sm mt-0.5" checked={@remember} $change={:set_field, field: :remember} />
              <span>
                Remember this device. Next time this browser opens the vault without asking. Anyone who can use
                this unlocked browser profile can open your vault.
              </span>
            </label>
            {%if @error}
              <p id="setup-error" role="alert" class="text-sm text-error">{error_text(@error)}</p>
            {/if}
            <button id="setup-continue" type="submit" class="btn btn-primary">Continue</button>
          </form>
        {%else}
          <form id="setup-passkey-form" class="flex flex-col gap-3" $submit="continue">
            <p class="text-sm text-base-content/70">
              A passkey on this device unlocks the vault. You will also get a recovery key in the next step.
            </p>
            <label class="flex items-start gap-2 text-sm">
              <input id="setup-remember" type="checkbox" class="checkbox checkbox-sm mt-0.5" checked={@remember} $change={:set_field, field: :remember} />
              <span>
                Remember this device. Anyone who can use this unlocked browser profile can open your vault.
              </span>
            </label>
            {%if @error}
              <p id="setup-error" role="alert" class="text-sm text-error">{error_text(@error)}</p>
            {/if}
            <button id="setup-continue" type="submit" class="btn btn-primary">Create passkey</button>
          </form>
        {/if}
      {/if}

      {%if @step == :working}
        <p id="setup-busy" role="status" class="flex items-center gap-2">
          <span class="loading loading-spinner loading-sm"></span>
          Deriving your key. This takes a few seconds on purpose.
        </p>
      {/if}

      {%if @step == :recovery}
        <p class="text-base-content/70">
          This is your <strong>recovery key</strong>. If you lose your {method_name(@method)}, it is the only way
          back in. It is shown once and is not stored anywhere. Write it down or save it in a password manager now.
        </p>
        <div id="setup-recovery-key" class="grid grid-cols-3 sm:grid-cols-5 gap-2 font-mono text-sm bg-base-200 rounded p-3">
          {%for group <- groups(@recovery_key)}
            <span class="recovery-group">{group}</span>
          {/for}
        </div>
        <button id="setup-copy" type="button" class="btn btn-sm btn-outline self-start" $click="copy_key">
          {%if @copied}Copied{%else}Copy recovery key{/if}
        </button>
        <label class="flex items-start gap-2 text-sm">
          <input id="setup-ack-saved" type="checkbox" class="checkbox checkbox-sm mt-0.5" checked={@ack_saved} $change={:set_field, field: :ack_saved} />
          <span>I have saved my recovery key somewhere safe.</span>
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-sm font-medium">Type the last group of the key to confirm</span>
          <input id="setup-ack-final" type="text" autocomplete="off" autocapitalize="characters" spellcheck="false" class="input w-full font-mono" value={@ack_final} $change={:set_field, field: :ack_final} />
        </label>
        {%if @error}
          <p id="setup-error" role="alert" class="text-sm text-error">{error_text(@error)}</p>
        {/if}
        <button id="setup-finish" type="button" class="btn btn-primary" disabled={not ack_ok?(@recovery_key, @ack_saved, @ack_final)} $click="finish">
          Create my vault
        </button>
      {/if}

      {%if @step == :creating}
        {%if @vault.error}
          <p id="setup-create-error" role="alert" class="text-sm text-error">
            The vault could not be created. Nothing was saved. You can try again.
          </p>
          <button id="setup-retry" type="button" class="btn btn-primary self-start" $click="retry">Try again</button>
        {%else}
          <p id="setup-creating" role="status" class="flex items-center gap-2">
            <span class="loading loading-spinner loading-sm"></span> Creating your encrypted vault...
          </p>
        {/if}
      {/if}
    </section>
    """
  end

  # --- template helpers -------------------------------------------------------

  def method_class(true), do: "btn btn-primary btn-sm sm:btn-md"
  def method_class(false), do: "btn btn-outline btn-sm sm:btn-md"

  def method_name(:passkey), do: "passkey"
  def method_name(_), do: "passphrase"

  def groups(nil), do: []
  def groups(key), do: Recovery.groups(key)

  def ack_ok?(nil, _saved, _typed), do: false
  def ack_ok?(key, saved, typed), do: saved == true and Recovery.ack_ok?(key, typed)

  def error_text(:too_short), do: "Use at least 12 characters."
  def error_text(:mismatch), do: "The two passphrases do not match."

  def error_text(:weak),
    do: "That passphrase is too easy to guess. Try a longer, more unusual one."

  def error_text(:cancelled), do: "The passkey prompt was cancelled."

  def error_text(:unsupported),
    do: "This browser or device cannot use a passkey for encryption. Use a passphrase instead."

  def error_text(:ack), do: "Confirm that you saved the recovery key and type its last group."
  def error_text(_), do: "Something went wrong. Nothing was saved. Please try again."

  # --- actions ------------------------------------------------------------------

  def action(:set_method, %{method: method}, component),
    do: component |> put_state(:method, method) |> put_state(:error, nil)

  def action(:set_field, %{field: :passphrase, event: %{value: value}}, component) do
    component |> put_state(:passphrase, value) |> put_state(:strength, Strength.estimate(value))
  end

  def action(:set_field, %{field: field, event: %{value: value}}, component),
    do: put_state(component, field, value)

  def action(:continue, _params, component) do
    s = component.state

    cond do
      s.method == :passphrase and not s.strength.long_enough? ->
        put_state(component, :error, :too_short)

      s.method == :passphrase and s.passphrase != s.confirm ->
        put_state(component, :error, :mismatch)

      s.method == :passphrase and not s.strength.acceptable? ->
        put_state(component, :error, :weak)

      true ->
        # Paint the busy state first; Argon2id then blocks this component's
        # actions for a few seconds.
        component
        |> put_state(:step, :working)
        |> put_state(:error, nil)
        |> put_action(name: :do_wrap, delay: 40)
    end
  end

  def action(:do_wrap, _params, component) do
    s = component.state
    ws = component.props.account.workspace.id
    wrap_id = VaultEnv.random_uuid()
    recovery_id = VaultEnv.random_uuid()

    with {:ok, handle} <- Crypto.new_vault(),
         {:ok, method_wrap} <- wrap_method(s, handle, ws, wrap_id, component),
         {:ok, rec} <- Crypto.wrap_recovery(handle, ws, recovery_id) do
      recovery_wrap = %{
        id: recovery_id,
        kind: "recovery",
        label: "Recovery key",
        wrapped_key: rec.wrapped_key
      }

      component
      |> put_state(:handle, handle)
      |> put_state(:wraps, [method_wrap, recovery_wrap])
      |> put_state(:recovery_key, rec.recovery_key)
      |> put_state(:passphrase, "")
      |> put_state(:confirm, "")
      |> put_state(:step, :recovery)
    else
      {:error, code} ->
        component
        |> discard_handle()
        |> put_state(:step, :choose)
        |> put_state(:error, error_for(code))
    end
  end

  def action(:copy_key, _params, component) do
    VaultEnv.copy_text(component.state.recovery_key)
    put_state(component, :copied, true)
  end

  def action(:finish, _params, component) do
    s = component.state

    if ack_ok?(s.recovery_key, s.ack_saved, s.ack_final) do
      component
      |> put_state(:step, :creating)
      |> put_state(:error, nil)
      |> put_action(name: :do_finish, delay: 20)
    else
      put_state(component, :error, :ack)
    end
  end

  def action(:do_finish, _params, component) do
    s = component.state
    ws = component.props.account.workspace.id
    doc = component.props.initial_doc || VaultDoc.new()

    case Crypto.encrypt_document(s.handle, ws, 1, VaultDoc.encode(doc)) do
      {:ok, blob} ->
        # The recovery key leaves this component's memory with the hand-off.
        component
        |> put_state(:recovery_key, nil)
        |> put_state(:ack_final, "")
        |> put_state(:ack_saved, false)
        |> put_action(
          name: :vault_create_request,
          target: "page",
          params: %{
            handle: s.handle,
            blob: blob,
            wraps: s.wraps,
            doc: doc,
            remember: s.remember
          }
        )

      {:error, code} ->
        put_state(component, :error, error_for(code))
    end
  end

  # After a failed create the page flags `vault.error`; go back to the
  # acknowledged recovery step (the recovery key is gone, so restart).
  def action(:retry, _params, component) do
    component
    |> discard_handle()
    |> put_action(name: :vault_reset_error, target: "page")
    |> reset()
  end

  # --- internals -----------------------------------------------------------------

  defp wrap_method(%{method: :passphrase} = s, handle, ws, id, _component) do
    with {:ok, w} <- Crypto.wrap_passphrase(handle, s.passphrase, ws, id) do
      {:ok,
       %{
         id: id,
         kind: "passphrase",
         label: "Passphrase",
         salt: w.salt,
         kdf_params: w.kdf_params,
         wrapped_key: w.wrapped_key
       }}
    end
  end

  defp wrap_method(%{method: :passkey}, handle, ws, id, component) do
    opts = %{
      rp_id: "",
      rp_name: "Debt Relief Tracker",
      user_name: component.props.account.user.email
    }

    with {:ok, w} <- Crypto.wrap_passkey(handle, ws, id, opts) do
      {:ok,
       %{
         id: id,
         kind: "passkey",
         label: "Passkey",
         credential_id: w.credential_id,
         wrapped_key: w.wrapped_key
       }}
    end
  end

  defp error_for(:passkey_cancelled), do: :cancelled
  defp error_for(:passkey_unsupported), do: :unsupported
  defp error_for(_), do: :failed

  defp discard_handle(component) do
    if component.state.handle, do: Crypto.lock(component.state.handle)
    put_state(component, :handle, nil)
  end

  defp reset(component) do
    put_state(component,
      step: :choose,
      passphrase: "",
      confirm: "",
      strength: Strength.estimate(""),
      error: nil,
      handle: nil,
      wraps: [],
      recovery_key: nil,
      ack_saved: false,
      ack_final: ""
    )
  end
end
