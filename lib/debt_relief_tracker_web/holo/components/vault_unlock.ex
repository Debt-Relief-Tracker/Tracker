defmodule DebtReliefTrackerWeb.Holo.Components.VaultUnlock do
  @moduledoc """
  The unlock screen for an existing vault (ADR 0007, "Unlock"). One section per
  enrolled unlock method kind (the server's `key_wraps` list is metadata the
  server sees anyway), plus "Unlock this device" when a remembered-device key
  exists.

    * **Passphrase** -- Argon2id with the wrap's STORED params (the facade
      bounds-checks them), then unwrap.
    * **Passkey** -- WebAuthn `get()` with the PRF extension.
    * **Recovery key** -- typed, tolerant of case/dashes; a mistyped key
      (`:bad_recovery_key`, checksum) gets its own message.

  A wrong secret shows ONE generic failure message whatever the method or the
  reason (`VaultClient.Delay`: from the third consecutive failure a growing
  wait, 1 s, 2 s, 4 s ... capped at 30 s, enforced here in UI state). On
  success only an opaque session handle goes to the page (`:vault_opened`);
  the page fetches and decrypts the document.
  """

  use Hologram.Component

  alias DebtReliefTracker.{Crypto, VaultEnv}
  alias DebtReliefTracker.VaultClient.Delay

  prop :vault, :map
  prop :account, :map

  def init(_props, component) do
    put_state(component,
      passphrase: "",
      recovery: "",
      remember: false,
      busy: nil,
      error: nil,
      wait: 0,
      delay: Delay.new()
    )
  end

  def init(props, component, server), do: {init(props, component), server}

  def template do
    ~HOLO"""
    <section id="vault-unlock" class="w-full max-w-md flex flex-col gap-5 text-left">
      <h2 class="text-xl font-semibold text-center">Unlock your vault</h2>
      <p class="text-base-content/70 text-center">
        Your data is encrypted. Unlocking happens in this browser; the server never sees your passphrase, keys or data.
      </p>

      {%if @vault.other_tab == :unlocked}
        <p id="unlock-other-tab" class="text-sm text-info text-center">The vault is unlocked in another tab of this browser.</p>
      {/if}

      {%if shown_error(@error, @vault.error)}
        <p id="unlock-error" role="alert" class="text-sm text-error text-center">{error_text(shown_error(@error, @vault.error))}</p>
      {/if}
      {%if @wait > 0}
        <p id="unlock-delay" role="status" class="text-sm text-warning text-center">
          Too many attempts. Try again in {@wait} s.
        </p>
      {/if}

      {%if @busy}
        <p id="unlock-busy" role="status" class="flex items-center justify-center gap-2">
          <span class="loading loading-spinner loading-sm"></span> Unlocking...
        </p>
      {/if}

      {%if @vault.device}
        <button id="unlock-device-btn" type="button" class="btn btn-primary" disabled={@busy != nil} $click="unlock_device">
          Unlock this device
        </button>
      {/if}

      {%if @vault.has.passphrase}
        <form id="unlock-passphrase-form" class="flex flex-col gap-2" $submit="submit_passphrase">
          <label class="flex flex-col gap-1">
            <span class="text-sm font-medium">Passphrase</span>
            <input id="unlock-passphrase-input" type="password" autocomplete="current-password" class="input w-full" value={@passphrase} $change={:set_field, field: :passphrase} />
          </label>
          <button id="unlock-passphrase-submit" type="submit" class="btn btn-primary" disabled={@busy != nil}>Unlock with passphrase</button>
        </form>
      {/if}

      {%if @vault.has.passkey}
        <button id="unlock-passkey-btn" type="button" class="btn btn-outline" disabled={@busy != nil} $click="submit_passkey">
          Unlock with passkey
        </button>
      {/if}

      {%if @vault.has.recovery}
        <form id="unlock-recovery-form" class="flex flex-col gap-2" $submit="submit_recovery">
          <label class="flex flex-col gap-1">
            <span class="text-sm font-medium">Recovery key</span>
            <input id="unlock-recovery-input" type="text" autocomplete="off" autocapitalize="characters" spellcheck="false" class="input w-full font-mono" value={@recovery} $change={:set_field, field: :recovery} />
          </label>
          <button id="unlock-recovery-submit" type="submit" class="btn btn-outline" disabled={@busy != nil}>Unlock with recovery key</button>
        </form>
      {/if}

      <label class="flex items-start gap-2 text-sm">
        <input id="unlock-remember" type="checkbox" class="checkbox checkbox-sm mt-0.5" checked={@remember} $change={:set_field, field: :remember} />
        <span>
          Remember this device. Next time this browser opens the vault without asking. Anyone who can use this
          unlocked browser profile can open your vault.
        </span>
      </label>

      <button id="unlock-methods-btn" type="button" class="btn btn-ghost btn-sm self-center" $click={action: :open_modal, target: "page", params: %{modal: %{type: :vault_methods}}}>
        Unlock methods and start over
      </button>
    </section>
    """
  end

  # The component's own error wins; a failure reported by the page (the
  # document could not be decrypted after a successful unwrap) is generic.
  def shown_error(nil, nil), do: nil
  def shown_error(nil, _page_error), do: :failed
  def shown_error(error, _page_error), do: error

  def error_text(:bad_recovery_key),
    do:
      "That does not look like a valid recovery key. Check for typos: it has 14 groups of 4 characters."

  def error_text(:cancelled), do: "The passkey prompt was cancelled."
  def error_text(:unavailable), do: "Passkeys are not available in this browser."
  def error_text(:empty), do: "Enter your secret first."
  def error_text(_), do: "Could not unlock. Check what you entered and try again."

  # --- actions ------------------------------------------------------------------

  def action(:set_field, %{field: field, event: %{value: value}}, component),
    do: put_state(component, field, value)

  def action(:submit_passphrase, _params, component),
    do: start(component, :passphrase, component.state.passphrase)

  def action(:submit_recovery, _params, component),
    do: start(component, :recovery, component.state.recovery)

  def action(:submit_passkey, _params, component), do: start(component, :passkey, "-")
  def action(:unlock_device, _params, component), do: start(component, :device, "-")

  def action(:attempt, %{method: method}, component) do
    ws = component.props.account.workspace.id
    wraps = component.props.vault.wraps
    state = component.state

    # Direct recursion, no closures: an await inside an anonymous function is
    # not awaited by Hologram's interpreter.
    result =
      case method do
        :passphrase ->
          try_passphrase(for(w <- wraps, w.kind == "passphrase", do: w), state.passphrase, ws)

        :recovery ->
          try_recovery(for(w <- wraps, w.kind == "recovery", do: w), state.recovery, ws)

        :passkey ->
          try_passkey(for(w <- wraps, w.kind == "passkey", do: w), ws)

        :device ->
          Crypto.unlock_device(ws)
      end

    finish(component, result, method)
  end

  # --- internals -------------------------------------------------------------------

  defp start(component, method, secret) do
    now = VaultEnv.now_ms()
    wait = Delay.remaining_seconds(component.state.delay, now)

    cond do
      component.state.busy != nil ->
        component

      secret == "" ->
        put_state(component, :error, :empty)

      wait > 0 ->
        component |> put_state(:wait, wait) |> put_state(:error, nil)

      true ->
        component
        |> put_state(:busy, method)
        |> put_state(:error, nil)
        |> put_state(:wait, 0)
        |> put_action(name: :attempt, params: %{method: method}, delay: 40)
    end
  end

  # Tries each wrap of the kind in turn; a wrong secret moves on, any other
  # error stops.
  defp try_passphrase([], _pass, _ws), do: {:error, :decrypt_failed}

  defp try_passphrase([wrap | rest], pass, ws) do
    case Crypto.unlock_passphrase(pass, ws, wrap) do
      {:ok, handle} -> {:ok, handle}
      {:error, :decrypt_failed} -> try_passphrase(rest, pass, ws)
      {:error, _} = error -> error
    end
  end

  defp try_recovery([], _text, _ws), do: {:error, :decrypt_failed}

  defp try_recovery([wrap | rest], text, ws) do
    case Crypto.unlock_recovery(text, ws, wrap) do
      {:ok, handle} -> {:ok, handle}
      {:error, :decrypt_failed} -> try_recovery(rest, text, ws)
      {:error, _} = error -> error
    end
  end

  defp try_passkey([], _ws), do: {:error, :decrypt_failed}

  defp try_passkey([wrap | rest], ws) do
    case Crypto.unlock_passkey(ws, "", wrap) do
      {:ok, handle} -> {:ok, handle}
      {:error, :decrypt_failed} -> try_passkey(rest, ws)
      {:error, _} = error -> error
    end
  end

  defp finish(component, {:ok, handle}, method) do
    remember = component.state.remember and method != :device

    component
    |> put_state(busy: nil, error: nil, wait: 0, passphrase: "", recovery: "")
    |> put_state(:delay, Delay.new())
    |> put_action(
      name: :vault_opened,
      target: "page",
      params: %{handle: handle, remember: remember, method: method}
    )
  end

  defp finish(component, {:error, code}, _method) do
    case code do
      :bad_recovery_key ->
        component |> put_state(busy: nil, error: :bad_recovery_key)

      :passkey_cancelled ->
        component |> put_state(busy: nil, error: :cancelled)

      :passkey_unsupported ->
        component |> put_state(busy: nil, error: :unavailable)

      _ ->
        delay = Delay.failed(component.state.delay, VaultEnv.now_ms())

        component
        |> put_state(busy: nil, error: :failed, delay: delay)
        |> put_state(:wait, Delay.remaining_seconds(delay, VaultEnv.now_ms()))
    end
  end
end
