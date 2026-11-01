defmodule DebtReliefTrackerWeb.Holo.VaultFlow do
  @moduledoc """
  The client-side E2EE state machine behind `DashboardPage` (ADR 0007, roadmap
  Phases 7-8). Every function takes and returns the page's component struct;
  `DashboardPage.action/3` clauses delegate here. Runs in the browser (Hologram
  compiles it), so it is client-safe code and holds NO key material: the
  unlocked vault is an opaque `handle` into the `Crypto` facade.

  ## Page state (E2EE mode)

    * `doc` -- the decrypted `VaultDoc` (memory only; `nil` while locked)
    * `snapshot` -- `VaultDoc.view(doc)` (what the UI renders; `nil` while locked)
    * `sync` -- `VaultClient.SaveLoop` state (`nil` while locked)
    * `vault` -- see `new_vault/2`:
      `phase` (`:no_vault | :locked | :unlocked`), `wraps` (server-visible
      metadata + wrapped keys), `has` (kinds present), `handle`, `can_manage`,
      `device` (remembered-device key exists), `prf`, `busy`, `flow`
      (`:open | :refresh | nil`: what a pending `fetch_vault` is for), `error`,
      `rollback`/`pending` (rollback warning and the held server state),
      `creating`, `inflight`, `locking`/`lock_blocked`, `methods`, `notice`,
      `other_tab`, `idle_ms`, `test_hook`.

  ## Phase machine

      no_vault --create (wizard)--> unlocked
      locked --unlock (handle) + fetch + decrypt--> unlocked
      unlocked --lock / idle / remote lock--> locked   (flush first; if the
                  save fails the vault stays unlocked and says so)
      any --delete vault--> no_vault

  ## Save/sync loop (`VaultClient.SaveLoop` decides, this module acts)

      edit  -> Ledger.apply_change -> snapshot = view(doc) -> dirty -> debounce 1 s
      flush -> encrypt (fresh IV, AAD rev = base_rev + 1) -> save_vault(base_rev)
      ok       -> base_rev = rev; remember (rev, SHA-256) for rollback detection
      conflict -> decrypt the server doc, Merge.merge(local, remote), retry
                  (backoff 0.5 s .. 30 s, at most 6 retries, then :failed but still dirty)
      error    -> :offline, retry with backoff

  A dirty change is never dropped; leaving the page warns while unsaved.

  A Hologram handler may queue ONE follow-up action; each function below ends
  in at most one `put_action`.
  """

  import Hologram.Component,
    only: [put_state: 3, put_action: 2]

  alias DebtReliefTracker.{Crypto, VaultDoc, VaultEnv}
  alias DebtReliefTracker.VaultClient.SaveLoop
  alias DebtReliefTracker.VaultDoc.{Ledger, Merge}
  alias DebtReliefTrackerWeb.Holo.QuietJS

  # --- initial state (server `init/3`, so no JS here) -------------------------------

  @doc "The `vault` page-state map. `wraps` are the server-visible wrap maps."
  def new_vault(wraps, opts) do
    %{
      phase: if(wraps == [], do: :no_vault, else: :locked),
      wraps: wraps,
      has: has(wraps),
      handle: nil,
      can_manage: false,
      device: false,
      prf: false,
      busy: nil,
      flow: nil,
      error: nil,
      rollback: nil,
      pending: nil,
      creating: nil,
      inflight: nil,
      locking: nil,
      lock_blocked: false,
      methods: %{busy: false, status: nil, message: nil, queue: [], removing: nil},
      notice: nil,
      other_tab: nil,
      idle_ms: Keyword.fetch!(opts, :idle_ms),
      test_hook: Keyword.fetch!(opts, :test_hook)
    }
  end

  def has(wraps) do
    %{
      passphrase: Enum.any?(wraps, &(&1.kind == "passphrase")),
      passkey: Enum.any?(wraps, &(&1.kind == "passkey")),
      recovery: Enum.any?(wraps, &(&1.kind == "recovery"))
    }
  end

  # --- boot (client, on mount) ----------------------------------------------------------

  def boot(c) do
    QuietJS.quiet()
    ws = ws(c)
    VaultEnv.init(ws)
    prf = Crypto.prf_supported?()
    device = Crypto.device_remembered?(ws)
    c = merge(c, %{prf: prf, device: device})

    if c.state.vault.phase == :locked and device do
      case Crypto.unlock_device(ws) do
        {:ok, handle} -> opened(c, %{handle: handle, remember: false, method: :device})
        {:error, _} -> merge(c, %{device: false})
      end
    else
      c
    end
  end

  # --- unlocking -------------------------------------------------------------------------

  @doc "An unlock method produced a session handle: fetch the vault and decrypt it."
  def opened(c, %{handle: handle, remember: remember, method: _method}) do
    ws = ws(c)
    if remember, do: Crypto.remember_device(handle, ws)

    c
    |> merge(%{
      handle: handle,
      can_manage: Crypto.can_manage?(handle),
      device: Crypto.device_remembered?(ws),
      busy: :opening,
      flow: :open,
      error: nil
    })
    |> put_action(name: :fetch_vault, target: "vault_gate")
  end

  @doc "A `VaultGate` command reply."
  def result(c, %{op: :fetch_vault} = r), do: fetched(c, r)
  def result(c, %{op: :create_vault} = r), do: created(c, r)
  def result(c, %{op: :save_vault} = r), do: saved(c, r)
  def result(c, %{op: :add_key_wrap} = r), do: wrap_added(c, r)
  def result(c, %{op: :remove_key_wrap} = r), do: wrap_removed(c, r)
  def result(c, %{op: :rename_key_wrap} = r), do: wrap_renamed(c, r)
  def result(c, %{op: :delete_vault} = r), do: deleted(c, r)
  def result(c, _other), do: c

  defp fetched(c, r) do
    vault = c.state.vault
    c = merge(c, %{flow: nil})

    cond do
      vault.flow == :open and r.ok and r.exists ->
        c |> set_wraps(r.key_wraps) |> ingest(:open, r.rev, r.blob)

      vault.flow == :open and r.ok ->
        # The vault was deleted elsewhere since this page loaded.
        Crypto.lock(vault.handle)

        c
        |> set_wraps([])
        |> merge(%{handle: nil, phase: :no_vault, busy: nil, can_manage: false})

      vault.flow == :open ->
        Crypto.lock(vault.handle)
        merge(c, %{handle: nil, busy: nil, can_manage: false, error: :unlock_failed})

      vault.flow == :refresh and r.ok and r.exists and vault.phase == :unlocked ->
        c |> set_wraps(r.key_wraps) |> ingest(:refresh, r.rev, r.blob)

      true ->
        c
    end
  end

  # Rollback check first (the server may serve an older or substituted blob),
  # then decrypt + decode + adopt.
  defp ingest(c, mode, rev, blob) do
    ws = ws(c)

    case Crypto.seen_check(ws, rev, blob) do
      {:ok, "rollback"} ->
        merge(c, %{
          rollback: %{rev: rev, mode: mode},
          pending: %{mode: mode, rev: rev, blob: blob},
          busy: nil
        })

      _ ->
        continue(c, mode, rev, blob)
    end
  end

  defp continue(c, mode, rev, blob) do
    ws = ws(c)

    with {:ok, text} <- Crypto.decrypt_document(c.state.vault.handle, ws, rev, blob),
         {:ok, remote} <- VaultDoc.decode(text) do
      Crypto.seen_record(ws, rev, blob)
      adopt(c, mode, rev, remote)
    else
      _ -> undecryptable(c, mode)
    end
  end

  # The explicit "I understand, continue" after a rollback warning.
  def rollback_ack(c) do
    case c.state.vault.pending do
      %{mode: mode, rev: rev, blob: blob} ->
        c |> merge(%{rollback: nil, pending: nil}) |> continue(mode, rev, blob)

      _ ->
        merge(c, %{rollback: nil, pending: nil})
    end
  end

  # Tampered or wrong-key document: one generic failure, no crash.
  defp undecryptable(c, :open) do
    Crypto.lock(c.state.vault.handle)

    merge(c, %{
      handle: nil,
      can_manage: false,
      busy: nil,
      flow: nil,
      error: :unlock_failed,
      phase: :locked
    })
  end

  defp undecryptable(c, _mode) do
    sync = %{c.state.sync | status: :failed}

    c
    |> put_state(:sync, sync)
    |> merge(%{inflight: nil, locking: nil, lock_blocked: c.state.vault.locking != nil})
  end

  defp adopt(c, :open, rev, remote) do
    vault = c.state.vault
    ctx = ctx(c)

    {doc, changed?} =
      case Ledger.catch_up(remote, ctx) do
        {:ok, doc, _report} -> {doc, doc != remote}
        _ -> {remote, false}
      end

    sync = SaveLoop.new(rev)
    {sync, token} = if changed?, do: SaveLoop.changed(sync), else: {sync, nil}

    c =
      c
      |> put_state(:doc, doc)
      |> put_state(:snapshot, VaultDoc.view(doc))
      |> put_state(:sync, sync)
      |> merge(%{
        phase: :unlocked,
        busy: nil,
        flow: nil,
        error: nil,
        rollback: nil,
        pending: nil,
        other_tab: nil,
        lock_blocked: false
      })

    VaultEnv.idle_start(vault.idle_ms)
    VaultEnv.broadcast("unlocked")
    sync_flag(c)

    c
    |> schedule(token, SaveLoop.debounce_ms())
    |> plan_changed()
  end

  defp adopt(c, :refresh, rev, remote) do
    merged = Merge.merge(c.state.doc, remote)
    {sync, token} = SaveLoop.remote_merged(c.state.sync, rev, merged != remote)

    c
    |> put_state(:doc, merged)
    |> put_state(:snapshot, VaultDoc.view(merged))
    |> put_state(:sync, sync)
    |> tap_flag()
    |> schedule(if(sync.dirty?, do: token, else: nil), SaveLoop.debounce_ms())
  end

  defp adopt(c, :conflict, rev, remote) do
    merged = Merge.merge(c.state.doc, remote)
    {sync, action} = SaveLoop.conflicted(c.state.sync, rev)

    c =
      c
      |> put_state(:doc, merged)
      |> put_state(:snapshot, VaultDoc.view(merged))
      |> put_state(:sync, sync)
      |> merge(%{inflight: nil})
      |> tap_flag()

    retry_or_give_up(c, action)
  end

  # --- creating (wizard hand-off) ---------------------------------------------------------

  def create_request(c, %{handle: handle, blob: blob, wraps: wraps, doc: doc, remember: remember}) do
    c
    |> merge(%{
      busy: :creating,
      error: nil,
      creating: %{handle: handle, blob: blob, wraps: wraps, doc: doc, remember: remember}
    })
    |> put_action(
      name: :create_vault,
      target: "vault_gate",
      params: %{blob: blob, wraps: wraps}
    )
  end

  defp created(c, r) do
    creating = c.state.vault.creating

    if r.ok and creating != nil do
      ws = ws(c)
      Crypto.seen_record(ws, 1, creating.blob)
      if creating.remember, do: Crypto.remember_device(creating.handle, ws)
      now = VaultEnv.now_iso()
      wraps = for w <- creating.wraps, do: wrap_with_defaults(w, now)
      doc = creating.doc

      c =
        c
        |> put_state(:doc, doc)
        |> put_state(:snapshot, VaultDoc.view(doc))
        |> put_state(:sync, SaveLoop.new(1))
        |> set_wraps(wraps)
        |> merge(%{
          phase: :unlocked,
          handle: creating.handle,
          can_manage: true,
          device: Crypto.device_remembered?(ws),
          busy: nil,
          error: nil,
          creating: nil,
          notice: :created
        })

      VaultEnv.idle_start(c.state.vault.idle_ms)
      VaultEnv.broadcast("unlocked")
      plan_changed(c)
    else
      if creating, do: Crypto.lock(creating.handle)
      merge(c, %{busy: nil, error: :create_failed, creating: nil})
    end
  end

  # The dashboard components mount (or, after a lock, remount with their old
  # state) when the vault opens: have the plan panel derive from the document.
  defp plan_changed(c),
    do: put_action(c, name: :plan_inputs_changed, target: "plan_panel", delay: 50)

  defp wrap_with_defaults(w, now) do
    Map.merge(%{salt: nil, kdf_params: nil, credential_id: nil, inserted_at: now}, w)
  end

  # --- editing and saving -----------------------------------------------------------------

  @doc "Applies a `Storage` change through the ledger and schedules a debounced save."
  def apply_change(c, change) do
    cond do
      c.state.vault.phase != :unlocked or c.state.doc == nil ->
        c

      true ->
        case Ledger.apply_change(c.state.doc, change, ctx(c)) do
          {:ok, doc} ->
            {sync, token} = SaveLoop.changed(c.state.sync)

            c
            |> put_state(:doc, doc)
            |> put_state(:snapshot, VaultDoc.view(doc))
            |> put_state(:sync, sync)
            |> put_state(:error, nil)
            |> tap_flag()
            |> schedule(token, SaveLoop.debounce_ms())

          {:error, error} ->
            put_state(c, :error, error)
        end
    end
  end

  @doc """
  The one way the dashboard changes vault data (ADR 0007, "Data path"):
  applies `request.changes` (a list, all-or-nothing) through the ledger and
  schedules the debounced encrypted save. Feature components send this through
  `Holo.DataPath.save/4`; `request`:

      %{
        changes: [Storage change],
        ok:    %{target: cid | "page", name: action, params: map},
        error: %{target: cid | "page", name: action},
        members: nil | %{user_id => display_name}   # retirement member picker
      }

  The handler's single follow-up action is the reply: `ok` gets
  `params` plus `snapshot` (the new view) and `today` (the client's date);
  `error` gets `%{error: error}` (`Storage.error`, same shapes as the server
  path so components render it with the same code).
  """
  def apply_request(c, %{changes: changes, ok: ok, error: error} = req) do
    cond do
      changes == [] and c.state.doc != nil ->
        put_action(c,
          name: ok.name,
          target: ok.target,
          params: Map.merge(ok.params, %{snapshot: c.state.snapshot, today: VaultEnv.today_iso()})
        )

      c.state.vault.phase != :unlocked or c.state.doc == nil ->
        c

      true ->
        case apply_all(c.state.doc, changes, ctx(c, Map.get(req, :members))) do
          {:ok, doc} ->
            {sync, token} = SaveLoop.changed(c.state.sync)
            snapshot = VaultDoc.view(doc)

            c
            |> put_state(:doc, doc)
            |> put_state(:snapshot, snapshot)
            |> put_state(:sync, sync)
            |> put_state(:error, nil)
            |> tap_flag()
            |> schedule(token, SaveLoop.debounce_ms())
            |> put_action(
              name: ok.name,
              target: ok.target,
              params: Map.merge(ok.params, %{snapshot: snapshot, today: VaultEnv.today_iso()})
            )

          {:error, e} ->
            put_action(c, name: error.name, target: error.target, params: %{error: e})
        end
    end
  end

  defp apply_all(doc, [], _ctx), do: {:ok, doc}

  defp apply_all(doc, [change | rest], ctx) do
    case Ledger.apply_change(doc, change, ctx) do
      {:ok, doc} -> apply_all(doc, rest, ctx)
      {:error, _} = error -> error
    end
  end

  @doc "A debounce timer fired: save if it is still the latest edit and nothing is in flight."
  def flush(c, %{token: token}) do
    token = token_int(token)
    sync = c.state.sync

    if c.state.vault.phase == :unlocked and sync != nil and SaveLoop.flush_due?(sync, token) do
      rev = sync.base_rev + 1
      text = VaultDoc.encode(c.state.doc)

      case Crypto.encrypt_document(c.state.vault.handle, ws(c), rev, text) do
        {:ok, blob} ->
          sync = SaveLoop.flush_started(sync)

          c
          |> put_state(:sync, sync)
          |> merge(%{inflight: %{blob: blob, rev: rev}})
          |> tap_flag()
          |> put_action(
            name: :save_vault,
            target: "vault_gate",
            params: %{base_rev: sync.base_rev, blob: blob}
          )

        {:error, _} ->
          {sync, action} = SaveLoop.failed(sync)
          c |> put_state(:sync, sync) |> retry_or_give_up(action)
      end
    else
      c
    end
  end

  defp saved(c, %{ok: true, rev: rev}) do
    inflight = c.state.vault.inflight
    ws = ws(c)
    if inflight, do: Crypto.seen_record(ws, rev, inflight.blob)
    {sync, next} = SaveLoop.saved(c.state.sync, rev)
    c = c |> put_state(:sync, sync) |> merge(%{inflight: nil}) |> tap_flag()

    case next do
      :flush_again ->
        schedule(c, sync.seq, 0)

      :done ->
        if c.state.vault.locking != nil, do: do_lock(c), else: c
    end
  end

  defp saved(c, %{ok: false, error: :conflict, rev: rev, blob: blob}) do
    if c.state.sync == nil, do: c, else: ingest(c, :conflict, rev, blob)
  end

  defp saved(c, %{ok: false}) do
    if c.state.sync == nil do
      c
    else
      {sync, action} = SaveLoop.failed(c.state.sync)

      # A lock that was waiting for this save stops waiting: the vault stays
      # unlocked and says so (the change keeps retrying in the background).
      locking? = c.state.vault.locking != nil

      c
      |> put_state(:sync, sync)
      |> merge(%{inflight: nil})
      |> merge(if locking?, do: %{locking: nil, lock_blocked: true}, else: %{})
      |> tap_flag()
      |> retry_or_give_up(action)
    end
  end

  defp retry_or_give_up(c, {:retry, delay}), do: schedule(c, c.state.sync.seq, delay)

  defp retry_or_give_up(c, :give_up) do
    # The change stays dirty (and the unload warning on); a manual retry resets the budget.
    merge(c, %{lock_blocked: c.state.vault.locking != nil, locking: nil})
  end

  @doc "Manual retry after the loop gave up."
  def retry(c) do
    if c.state.sync == nil do
      c
    else
      sync = SaveLoop.reset_retries(c.state.sync)
      {sync, token} = SaveLoop.changed(sync)
      c |> put_state(:sync, sync) |> merge(%{lock_blocked: false}) |> schedule(token, 0)
    end
  end

  # The debounce is a JS timer (`VaultEnv.flush_later/2`), not a delayed
  # `put_action`, so a handler's single follow-up action stays free for the
  # component reply of an edit (`apply_request/2`).
  defp schedule(c, nil, _delay), do: c

  defp schedule(c, token, delay) do
    VaultEnv.flush_later(token, delay)
    c
  end

  # The timer delivers the token as a string.
  defp token_int(t) when is_binary(t), do: String.to_integer(t)
  defp token_int(t), do: t

  # --- locking ------------------------------------------------------------------------------

  @doc """
  Lock the vault. Unsaved changes are saved first; if that fails the vault
  stays unlocked and says so (`lock_blocked`) rather than dropping them.
  `reason` is `:manual | :idle | :remote`.
  """
  def request_lock(c, reason) do
    sync = c.state.sync

    cond do
      c.state.vault.phase != :unlocked ->
        c

      sync == nil or not SaveLoop.unsaved?(sync) ->
        do_lock(c, reason != :remote)

      sync.inflight? ->
        merge(c, %{locking: reason})

      true ->
        c |> merge(%{locking: reason, lock_blocked: false}) |> flush(%{token: sync.seq})
    end
  end

  def lock_anyway(c), do: do_lock(c)

  defp do_lock(c, broadcast? \\ true) do
    vault = c.state.vault
    if vault.handle, do: Crypto.lock(vault.handle)
    VaultEnv.idle_stop()
    VaultEnv.set_dirty(false)
    if broadcast?, do: VaultEnv.broadcast("locked")

    c
    |> put_state(:doc, nil)
    |> put_state(:snapshot, nil)
    |> put_state(:sync, nil)
    |> put_state(:modal, nil)
    |> put_state(:error, nil)
    |> merge(%{
      phase: :locked,
      handle: nil,
      can_manage: false,
      busy: nil,
      flow: nil,
      locking: nil,
      lock_blocked: false,
      inflight: nil,
      rollback: nil,
      pending: nil,
      notice: nil,
      methods: %{busy: false, status: nil, message: nil, queue: [], removing: nil}
    })
  end

  @doc "Events from `VaultEnv` (JS): idle timeout, tab visible, other tabs locking/unlocking."
  def session_event(c, %{kind: "idle"}), do: request_lock(c, :idle)
  def session_event(c, %{kind: "remote_locked"}), do: request_lock(c, :remote)

  def session_event(c, %{kind: "remote_unlocked"}) do
    if c.state.vault.phase == :locked, do: merge(c, %{other_tab: :unlocked}), else: c
  end

  def session_event(c, %{kind: "visible"}) do
    vault = c.state.vault
    sync = c.state.sync

    if vault.phase == :unlocked and vault.flow == nil and vault.rollback == nil and sync != nil and
         not sync.inflight? do
      c |> merge(%{flow: :refresh}) |> put_action(name: :fetch_vault, target: "vault_gate")
    else
      c
    end
  end

  def session_event(c, _other), do: c

  # --- unlock methods (modal ops) ------------------------------------------------------------

  def methods_op(c, %{op: :add, wrap: wrap, remove: remove}) do
    c
    |> methods(%{busy: true, status: nil, message: nil, queue: remove, removing: nil})
    |> put_action(name: :add_key_wrap, target: "vault_gate", params: %{wrap: wrap})
  end

  def methods_op(c, %{op: :remove, id: id}) do
    c
    |> methods(%{busy: true, status: nil, message: nil, queue: [], removing: id})
    |> put_action(name: :remove_key_wrap, target: "vault_gate", params: %{id: id})
  end

  def methods_op(c, %{op: :rename, id: id, label: label}) do
    c
    |> methods(%{busy: true, status: nil, message: nil})
    |> put_action(name: :rename_key_wrap, target: "vault_gate", params: %{id: id, label: label})
  end

  def methods_op(c, %{op: :delete_vault}) do
    c
    |> methods(%{busy: true, status: nil, message: nil})
    |> put_action(name: :delete_vault, target: "vault_gate")
  end

  def methods_op(c, %{op: :device_changed, device: device}) do
    c |> merge(%{device: device}) |> methods(%{busy: false, status: :ok, message: :ok})
  end

  def methods_op(c, _other), do: c

  defp wrap_added(c, %{ok: true, key_wrap: wrap}) do
    c = set_wraps(c, c.state.vault.wraps ++ [wrap])

    case c.state.vault.methods.queue do
      [id | rest] ->
        c
        |> methods(%{queue: rest, removing: id})
        |> put_action(name: :remove_key_wrap, target: "vault_gate", params: %{id: id})

      [] ->
        methods(c, %{busy: false, status: :ok, message: :ok})
    end
  end

  defp wrap_added(c, r), do: methods_failed(c, r)

  defp wrap_removed(c, %{ok: true}) do
    id = c.state.vault.methods.removing
    c = set_wraps(c, for(w <- c.state.vault.wraps, w.id != id, do: w))

    case c.state.vault.methods.queue do
      [next | rest] ->
        c
        |> methods(%{queue: rest, removing: next})
        |> put_action(name: :remove_key_wrap, target: "vault_gate", params: %{id: next})

      [] ->
        methods(c, %{busy: false, status: :ok, message: :ok, removing: nil})
    end
  end

  defp wrap_removed(c, r), do: methods_failed(c, r)

  defp wrap_renamed(c, %{ok: true, key_wrap: wrap}) do
    wraps = for w <- c.state.vault.wraps, do: if(w.id == wrap.id, do: wrap, else: w)
    c |> set_wraps(wraps) |> methods(%{busy: false, status: :ok, message: :ok})
  end

  defp wrap_renamed(c, r), do: methods_failed(c, r)

  defp methods_failed(c, r) do
    methods(c, %{busy: false, status: :error, message: Map.get(r, :error, :failed), queue: []})
  end

  defp deleted(c, %{ok: true}) do
    ws = ws(c)
    Crypto.lock_all()
    Crypto.local_wipe(ws)
    VaultEnv.idle_stop()
    VaultEnv.set_dirty(false)
    VaultEnv.broadcast("locked")

    c
    |> put_state(:doc, nil)
    |> put_state(:snapshot, nil)
    |> put_state(:sync, nil)
    |> put_state(:modal, nil)
    |> set_wraps([])
    |> merge(%{
      phase: :no_vault,
      handle: nil,
      can_manage: false,
      device: false,
      busy: nil,
      flow: nil,
      error: nil,
      creating: nil,
      notice: nil,
      locking: nil,
      inflight: nil,
      methods: %{busy: false, status: nil, message: nil, queue: [], removing: nil}
    })
  end

  defp deleted(c, r), do: methods_failed(c, r)

  # --- test hook (minimal editing UI until the feature components use the ledger) -----------

  def test_hook_add(c, name) do
    apply_change(
      c,
      {:add_debt,
       %{
         name: name,
         type: "revolving",
         balance: 100_000,
         apr_bp: 1999,
         minimum_payment_floor: 3500,
         minimum_payment_rate_bp: 200
       }}
    )
  end

  # An automatic installment whose cycles since a year ago were never handled:
  # the NEXT open's `Ledger.catch_up` posts them.
  def test_hook_add_auto(c) do
    today = VaultEnv.today_iso()
    year = String.to_integer(String.slice(today, 0, 4)) - 1

    apply_change(
      c,
      {:add_debt,
       %{
         name: "Auto loan",
         type: "installment",
         balance: 120_000,
         original_balance: 120_000,
         apr_bp: 0,
         fixed_payment: 10_000,
         due_day: 1,
         auto_log_mode: "automatic",
         last_due_handled_on: Integer.to_string(year) <> String.slice(today, 4, 6)
       }}
    )
  end

  def test_hook_pay(c, id) do
    apply_change(c, {:log_payment, id, %{amount: 1000, paid_on: VaultEnv.today_iso()}})
  end

  def test_hook_delete(c, id), do: apply_change(c, {:delete_debt, id})

  # --- internals ----------------------------------------------------------------------------------

  defp ws(c), do: c.state.account.workspace.id

  defp ctx(c, members \\ nil) do
    %{
      now: VaultEnv.now_iso(),
      today: VaultEnv.today_iso(),
      new_id: fn -> VaultEnv.random_uuid() end,
      actor: c.state.account.user.id,
      members: members
    }
  end

  defp merge(c, changes), do: put_state(c, :vault, Map.merge(c.state.vault, changes))

  defp methods(c, changes) do
    merge(c, %{methods: Map.merge(c.state.vault.methods, changes)})
  end

  defp set_wraps(c, wraps), do: merge(c, %{wraps: wraps, has: has(wraps)})

  defp sync_flag(c) do
    VaultEnv.set_dirty(c.state.sync != nil and SaveLoop.unsaved?(c.state.sync))
  end

  defp tap_flag(c) do
    sync_flag(c)
    c
  end
end
