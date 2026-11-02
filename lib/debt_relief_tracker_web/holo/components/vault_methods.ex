defmodule DebtReliefTrackerWeb.Holo.Components.VaultMethods do
  @moduledoc """
  The "Unlock methods" modal (modal type `:vault_methods`), reachable from the
  locked screen and the unlocked page.

  Lists the vault's key wraps (kind, the label the user set, created date).
  Everything that changes a wrap needs an UNLOCKED session that holds the vault
  key (not merely a remembered device): add a passkey / passphrase,
  regenerate the recovery key (replaces the old recovery wrap), rename, remove
  (the server refuses the last one), and change the passphrase (verify the old
  one, wrap the same vault key under the new one, replace that one wrap --
  the document is never re-encrypted). "Start over" deletes the vault
  (typing DELETE); it also works while locked, for someone who lost every
  method.

  Crypto steps run here through the handle `Crypto` API; the server calls and
  the list of wraps belong to the page (`:vault_methods_op`).
  """

  use Hologram.Component

  alias DebtReliefTracker.{Crypto, VaultEnv}
  alias DebtReliefTracker.VaultClient.Recovery
  alias DebtReliefTrackerWeb.Holo.VaultFlow

  prop :vault, :map
  prop :account, :map

  def init(_props, component) do
    put_state(component,
      add_pass: "",
      add_confirm: "",
      old_pass: "",
      new_pass: "",
      new_confirm: "",
      rename_id: nil,
      rename_value: "",
      delete_text: "",
      rec_key: nil,
      rec_wrap: nil,
      rec_saved: false,
      rec_final: "",
      busy: false,
      error: nil
    )
  end

  def init(props, component, server), do: {init(props, component), server}

  def template do
    ~HOLO"""
    <div id="vault-methods-modal" class="fixed inset-0 bg-black/50 flex items-center justify-center p-4 sm:p-0 z-50">
      <window $key_down.escape={action: :close_modal, target: "page"} />
      <div class="bg-base-100 rounded-lg p-4 sm:p-6 w-full max-w-2xl max-h-[90vh] overflow-y-auto flex flex-col gap-5" $click_outside={action: :close_modal, target: "page"}>
        <div class="flex items-center justify-between">
          <h2 class="font-semibold text-lg">Unlock methods</h2>
          <button id="methods-close" type="button" class="btn btn-ghost btn-sm" aria-label="Close" $click={action: :close_modal, target: "page"}>Close</button>
        </div>

        {%if shown_message(@error, @vault.methods)}
          <p id="methods-status" role="status" class={status_class(@vault.methods)}>{message_text(shown_message(@error, @vault.methods))}</p>
        {/if}
        {%if @busy or @vault.methods.busy}
          <p id="methods-busy" role="status" class="flex items-center gap-2 text-sm">
            <span class="loading loading-spinner loading-sm"></span> Working...
          </p>
        {/if}

        {%if not @vault.can_manage}
          <p id="methods-readonly" class="text-sm text-base-content/70">
            {%if @vault.phase == :unlocked}
              This session was opened with a remembered device, which can read and save your data but cannot change
              how the vault is unlocked. Lock and unlock with your passphrase, passkey or recovery key to add or remove methods.
            {%else}
              Unlock the vault with a passphrase, passkey or recovery key to add or remove methods.
            {/if}
          </p>
        {/if}

        <ul id="methods-list" class="flex flex-col gap-2">
          {%for wrap <- @vault.wraps}
            <li id={"wrap-" <> wrap.id} class="flex flex-col sm:flex-row sm:items-center gap-2 border border-base-300 rounded p-2">
              <div class="flex-1 min-w-0">
                <span class="badge badge-outline mr-2">{kind_name(wrap.kind)}</span>
                <span class="wrap-label font-medium break-words">{wrap.label}</span>
                <span class="text-xs text-base-content/60 ml-2">added {created(wrap)}</span>
              </div>
              {%if @rename_id == wrap.id}
                <input id="methods-rename-input" type="text" maxlength="100" class="input input-sm w-full sm:w-48" value={@rename_value} $change={:set_field, field: :rename_value} />
                <button id="methods-rename-save" type="button" class="btn btn-sm btn-primary" $click="save_rename">Save</button>
              {%else}
                <button id={"wrap-rename-" <> wrap.id} type="button" class="btn btn-sm btn-ghost" disabled={not @vault.can_manage} $click={:start_rename, id: wrap.id, label: wrap.label}>Rename</button>
                <button id={"wrap-remove-" <> wrap.id} type="button" class="btn btn-sm btn-ghost text-error" disabled={not @vault.can_manage} $click={:remove, id: wrap.id}>Remove</button>
              {/if}
            </li>
          {/for}
        </ul>

        <div class="flex flex-col gap-4">
          <form id="methods-add-passphrase-form" class="flex flex-col gap-2" $submit="add_passphrase">
            <h3 class="font-medium">Add a passphrase</h3>
            <input id="methods-add-passphrase" type="password" autocomplete="new-password" placeholder="At least 12 characters" class="input w-full" value={@add_pass} $change={:set_field, field: :add_pass} />
            <input id="methods-add-confirm" type="password" autocomplete="new-password" placeholder="Confirm passphrase" class="input w-full" value={@add_confirm} $change={:set_field, field: :add_confirm} />
            <button id="methods-add-passphrase-submit" type="submit" class="btn btn-sm btn-outline self-start" disabled={not @vault.can_manage}>Add passphrase</button>
          </form>

          {%if @vault.prf}
            <div class="flex flex-col gap-2">
              <h3 class="font-medium">Add a passkey</h3>
              <button id="methods-add-passkey" type="button" class="btn btn-sm btn-outline self-start" disabled={not @vault.can_manage} $click="add_passkey">Add passkey</button>
            </div>
          {/if}

          {%if @vault.has.passphrase}
            <form id="methods-change-form" class="flex flex-col gap-2" $submit="change_passphrase">
              <h3 class="font-medium">Change passphrase</h3>
              <input id="methods-old-passphrase" type="password" autocomplete="current-password" placeholder="Current passphrase" class="input w-full" value={@old_pass} $change={:set_field, field: :old_pass} />
              <input id="methods-new-passphrase" type="password" autocomplete="new-password" placeholder="New passphrase (at least 12 characters)" class="input w-full" value={@new_pass} $change={:set_field, field: :new_pass} />
              <input id="methods-new-confirm" type="password" autocomplete="new-password" placeholder="Confirm new passphrase" class="input w-full" value={@new_confirm} $change={:set_field, field: :new_confirm} />
              <button id="methods-change-submit" type="submit" class="btn btn-sm btn-outline self-start" disabled={not @vault.can_manage}>Change passphrase</button>
            </form>
          {/if}

          <div class="flex flex-col gap-2">
            <h3 class="font-medium">Recovery key</h3>
            {%if @rec_key}
              <p class="text-sm text-base-content/70">
                This replaces your old recovery key, which stops working once you confirm. It is shown once.
              </p>
              <div id="methods-recovery-key" class="grid grid-cols-3 sm:grid-cols-5 gap-2 font-mono text-sm bg-base-200 rounded p-3">
                {%for group <- groups(@rec_key)}
                  <span class="recovery-group">{group}</span>
                {/for}
              </div>
              <label class="flex items-start gap-2 text-sm">
                <input id="methods-rec-saved" type="checkbox" class="checkbox checkbox-sm mt-0.5" checked={@rec_saved} $change={:set_field, field: :rec_saved} />
                <span>I have saved the new recovery key somewhere safe.</span>
              </label>
              <input id="methods-rec-final" type="text" autocomplete="off" spellcheck="false" placeholder="Last group of the key" class="input w-full font-mono" value={@rec_final} $change={:set_field, field: :rec_final} />
              <button id="methods-recovery-confirm" type="button" class="btn btn-sm btn-primary self-start" disabled={not rec_ack?(@rec_key, @rec_saved, @rec_final)} $click="confirm_recovery">Replace recovery key</button>
            {%else}
              <button id="methods-regen-recovery" type="button" class="btn btn-sm btn-outline self-start" disabled={not @vault.can_manage} $click="regen_recovery">
                Generate a new recovery key
              </button>
            {/if}
          </div>

          <div class="flex flex-col gap-2">
            <h3 class="font-medium">This device</h3>
            {%if @vault.device}
              <p class="text-sm text-base-content/70">This browser can open the vault without asking. Anyone who can use this unlocked browser profile can open your vault.</p>
              <button id="methods-forget-device" type="button" class="btn btn-sm btn-outline self-start" $click="forget_device">Forget this device</button>
            {%else}
              <button id="methods-remember-device" type="button" class="btn btn-sm btn-outline self-start" disabled={@vault.phase != :unlocked} $click="remember_device">Remember this device</button>
            {/if}
          </div>

          <div class="flex flex-col gap-2 border-t border-base-300 pt-4">
            <h3 class="font-medium text-error">Start over / delete vault</h3>
            <p class="text-sm text-base-content/70">
              Deletes the encrypted vault from the server and from this browser. Your data and every unlock method are
              gone and cannot be recovered by anyone. Use this only if you lost every way to unlock it.
            </p>
            <input id="methods-delete-input" type="text" autocomplete="off" placeholder="Type DELETE to confirm" class="input w-full" value={@delete_text} $change={:set_field, field: :delete_text} />
            <button id="methods-delete-confirm" type="button" class="btn btn-sm btn-error self-start" disabled={@delete_text != "DELETE"} $click="delete_vault">Delete vault forever</button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- template helpers ---------------------------------------------------------

  def kind_name("passphrase"), do: "Passphrase"
  def kind_name("passkey"), do: "Passkey"
  def kind_name("recovery"), do: "Recovery key"
  def kind_name(other), do: other

  def created(wrap), do: String.slice(wrap.inserted_at || "", 0, 10)

  def groups(nil), do: []
  def groups(key), do: Recovery.groups(key)

  def rec_ack?(nil, _saved, _typed), do: false
  def rec_ack?(key, saved, typed), do: saved == true and Recovery.ack_ok?(key, typed)

  def shown_message(nil, %{status: nil}), do: nil
  def shown_message(nil, %{message: message}), do: message
  def shown_message(error, _methods), do: error

  def status_class(%{status: :ok}), do: "text-sm text-success"
  def status_class(_), do: "text-sm text-error"

  def message_text(:ok), do: "Done."

  def message_text(:last_wrap),
    do: "You cannot remove your only unlock method. Add another one first."

  def message_text(:too_many_wraps), do: "There are too many unlock methods. Remove one first."

  def message_text(:too_many_passphrase_wraps),
    do: "There are already 3 passphrases. Remove one first."

  def message_text(:rate_limited), do: "Too many requests. Wait a moment and try again."
  def message_text(:too_short), do: "Use at least 12 characters."
  def message_text(:mismatch), do: "The two passphrases do not match."

  def message_text(:weak),
    do: "That passphrase is too easy to guess. Try a longer, more unusual one."

  def message_text(:wrong_passphrase), do: "The current passphrase is not correct."

  def message_text(:uv_required),
    do:
      "Passkeys here must verify you (PIN, biometric or device lock). This authenticator cannot, so use another method."

  def message_text(:cancelled), do: "The passkey prompt was cancelled."

  def message_text(:unsupported),
    do: "This browser or device cannot use a passkey for encryption."

  def message_text(:locked), do: "Unlock the vault first."
  def message_text(_), do: "That did not work. Nothing was changed."

  # --- actions ------------------------------------------------------------------------

  def action(:set_field, %{field: field, event: %{value: value}}, component),
    do: put_state(component, field, value)

  def action(:start_rename, %{id: id, label: label}, component),
    do: component |> put_state(:rename_id, id) |> put_state(:rename_value, label || "")

  def action(:save_rename, _params, component) do
    s = component.state

    component
    |> put_state(:rename_id, nil)
    |> put_action(
      name: :vault_methods_op,
      target: "page",
      params: %{op: :rename, id: s.rename_id, label: s.rename_value}
    )
  end

  def action(:remove, %{id: id}, component) do
    put_action(component,
      name: :vault_methods_op,
      target: "page",
      params: %{op: :remove, id: id}
    )
  end

  def action(:add_passphrase, _params, component) do
    s = component.state

    case check_new(s.add_pass, s.add_confirm) do
      :ok -> start(component, :do_add_passphrase)
      {:error, code} -> put_state(component, :error, code)
    end
  end

  def action(:do_add_passphrase, _params, component) do
    s = component.state
    ws = component.props.account.workspace.id
    id = VaultEnv.random_uuid()

    case Crypto.wrap_passphrase(component.props.vault.handle, s.add_pass, ws, id) do
      {:ok, w} ->
        wrap = %{
          id: id,
          kind: "passphrase",
          label: "Passphrase",
          salt: w.salt,
          kdf_params: w.kdf_params,
          wrapped_key: w.wrapped_key
        }

        component
        |> clear()
        |> put_state(:add_pass, "")
        |> put_state(:add_confirm, "")
        |> to_page(%{op: :add, wrap: wrap, remove: []})

      {:error, code} ->
        fail(component, code)
    end
  end

  def action(:add_passkey, _params, component), do: start(component, :do_add_passkey)

  def action(:do_add_passkey, _params, component) do
    ws = component.props.account.workspace.id
    id = VaultEnv.random_uuid()

    opts = %{
      rp_id: "",
      rp_name: "Debt Relief Tracker",
      user_name: component.props.account.user.email
    }

    case Crypto.wrap_passkey(component.props.vault.handle, ws, id, opts) do
      {:ok, w} ->
        wrap = %{
          id: id,
          kind: "passkey",
          label: "Passkey",
          credential_id: w.credential_id,
          wrapped_key: w.wrapped_key
        }

        component |> clear() |> to_page(%{op: :add, wrap: wrap, remove: []})

      {:error, code} ->
        fail(component, code)
    end
  end

  def action(:regen_recovery, _params, component), do: start(component, :do_regen_recovery)

  def action(:do_regen_recovery, _params, component) do
    ws = component.props.account.workspace.id
    id = VaultEnv.random_uuid()

    case Crypto.wrap_recovery(component.props.vault.handle, ws, id) do
      {:ok, rec} ->
        component
        |> clear()
        |> put_state(:rec_key, rec.recovery_key)
        |> put_state(:rec_wrap, %{
          id: id,
          kind: "recovery",
          label: "Recovery key",
          wrapped_key: rec.wrapped_key
        })
        |> put_state(:rec_saved, false)
        |> put_state(:rec_final, "")

      {:error, code} ->
        fail(component, code)
    end
  end

  def action(:confirm_recovery, _params, component) do
    s = component.state

    if rec_ack?(s.rec_key, s.rec_saved, s.rec_final) do
      old = for w <- component.props.vault.wraps, w.kind == "recovery", do: w.id

      component
      |> put_state(:rec_key, nil)
      |> put_state(:rec_final, "")
      |> put_state(:rec_saved, false)
      |> to_page(%{op: :add, wrap: s.rec_wrap, remove: old})
      |> put_state(:rec_wrap, nil)
    else
      component
    end
  end

  def action(:change_passphrase, _params, component) do
    s = component.state

    cond do
      s.old_pass == "" ->
        put_state(component, :error, :wrong_passphrase)

      true ->
        case check_new(s.new_pass, s.new_confirm) do
          :ok -> start(component, :do_change_passphrase)
          {:error, code} -> put_state(component, :error, code)
        end
    end
  end

  def action(:do_change_passphrase, _params, component) do
    s = component.state
    ws = component.props.account.workspace.id
    wraps = for w <- component.props.vault.wraps, w.kind == "passphrase", do: w

    case verify_old(wraps, s.old_pass, ws) do
      {:ok, old_wrap} ->
        id = VaultEnv.random_uuid()

        case Crypto.wrap_passphrase(component.props.vault.handle, s.new_pass, ws, id) do
          {:ok, w} ->
            wrap = %{
              id: id,
              kind: "passphrase",
              label: old_wrap.label || "Passphrase",
              salt: w.salt,
              kdf_params: w.kdf_params,
              wrapped_key: w.wrapped_key
            }

            component
            |> clear()
            |> put_state(old_pass: "", new_pass: "", new_confirm: "")
            |> to_page(%{op: :add, wrap: wrap, remove: [old_wrap.id]})

          {:error, code} ->
            fail(component, code)
        end

      {:error, _} ->
        fail(component, :wrong_passphrase)
    end
  end

  def action(:remember_device, _params, component) do
    ws = component.props.account.workspace.id

    case Crypto.remember_device(component.props.vault.handle, ws) do
      {:ok, _} -> to_page(component, %{op: :device_changed, device: true})
      {:error, code} -> fail(component, code)
    end
  end

  def action(:forget_device, _params, component) do
    ws = component.props.account.workspace.id
    Crypto.forget_device(ws)
    to_page(component, %{op: :device_changed, device: false})
  end

  def action(:delete_vault, _params, component) do
    if component.state.delete_text == "DELETE" do
      component |> put_state(:delete_text, "") |> to_page(%{op: :delete_vault})
    else
      component
    end
  end

  # --- internals -------------------------------------------------------------------------

  defp check_new(pass, confirm) do
    case VaultFlow.check_new_passphrase(pass) do
      {:error, :passphrase_too_short} -> {:error, :too_short}
      _ when pass != confirm -> {:error, :mismatch}
      {:error, :passphrase_weak} -> {:error, :weak}
      :ok -> :ok
    end
  end

  # Paint the busy state first; Argon2id / the passkey prompt then run.
  defp start(component, next) do
    component
    |> put_state(:busy, true)
    |> put_state(:error, nil)
    |> put_action(name: next, delay: 40)
  end

  defp clear(component), do: component |> put_state(:busy, false) |> put_state(:error, nil)

  defp fail(component, code) do
    put_state(component, busy: false, error: error_for(code))
  end

  defp error_for(:passkey_cancelled), do: :cancelled
  defp error_for(:passkey_unsupported), do: :unsupported
  defp error_for(:passkey_uv_unsupported), do: :uv_required
  defp error_for(:passphrase_too_short), do: :too_short
  defp error_for(:wrong_passphrase), do: :wrong_passphrase
  defp error_for(:locked), do: :locked
  defp error_for(_), do: :failed

  defp to_page(component, params) do
    put_action(component, name: :vault_methods_op, target: "page", params: params)
  end

  # Verifies the old passphrase against the passphrase wraps; returns the wrap
  # it opened. The temporary session is locked again immediately.
  defp verify_old([], _pass, _ws), do: {:error, :decrypt_failed}

  defp verify_old([wrap | rest], pass, ws) do
    case Crypto.unlock_passphrase(pass, ws, wrap) do
      {:ok, handle} ->
        Crypto.lock(handle)
        {:ok, wrap}

      {:error, _} ->
        verify_old(rest, pass, ws)
    end
  end
end
