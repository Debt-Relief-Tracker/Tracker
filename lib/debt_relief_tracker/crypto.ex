defmodule DebtReliefTracker.Crypto do
  @moduledoc """
  Elixir facade over `assets/js/crypto_facade.mjs`, the browser crypto layer
  for E2EE mode (ADR 0007). The only module that talks to that file.

  ## RAW KEY MATERIAL NEVER ENTERS ELIXIR

  This facade is a **handle API**. The unlocked vault (vault key bytes and a
  derived non-extractable CryptoKey) lives in module-private JS memory; Elixir
  and Hologram state hold only an opaque `handle` string (random, meaningless)
  plus ciphertext envelopes, ids and revisions. There is no function here that
  returns or accepts a vault key, KEK, or derived secret. Secrets that
  necessarily cross the boundary are the ones a human types or reads: a
  passphrase going in, and a newly generated recovery key text coming out once
  (to be shown to the user).

  Everything is a string. Wraps and ciphertext are `"v1.<iv>.<ct||tag>"`
  envelopes (AAD layouts in the facade header). Every function returns
  `{:ok, value}` or `{:error, code}` and never raises for crypto failures.
  Codes: `:decrypt_failed` (ONE code for wrong key, wrong AAD, tampering and
  malformed input, so there is no oracle), `:locked` (unknown handle),
  `:bad_input`, `:bad_params`, `:bad_recovery_key`, `:passkey_unsupported`,
  `:passkey_cancelled`, `:passkey_failed`, `:crypto_unavailable`,
  `:selftest_failed`, `:internal`, and `:not_in_browser`.

  The JS functions are async (Promises become Elixir Tasks), so these must be
  called from a Hologram action, which awaits them; a call blocks that
  component's later actions until it finishes. Argon2id at 64 MiB takes
  seconds on a phone, so put the UI in a "working" state first and chain the
  derive in a separate (delayed) action.

  Never log or store the returned values outside the intended places.
  """

  use Hologram.JS

  js_import from: "../../assets/js/crypto_facade.mjs", as: :CryptoFacade

  @type result(t) :: {:ok, t} | {:error, atom()}
  @type handle :: String.t()
  @type kind :: :passphrase | :passkey | :recovery

  # --- feature detection / self test -------------------------------------------

  @doc """
  Feature detection: false when WebAuthn is missing or the browser reports no
  PRF support. True is only confirmed when a credential is created.
  """
  def prf_supported? do
    case run(:prfSupported, []) do
      {:ok, "true"} -> true
      _ -> false
    end
  end

  @doc "Runs the facade's known-answer checks; `{:ok, \"ok\"}` or `{:error, :selftest_failed}`."
  def self_test, do: run(:selfTest, [])

  # --- sessions ------------------------------------------------------------------

  @doc "A new random vault key, unlocked under a fresh handle (setup wizard)."
  def new_vault, do: run(:vaultNew, [])

  @doc "Locks one session: overwrites its key bytes and forgets the handle."
  def lock(handle), do: run(:vaultLock, [handle])

  @doc "Locks every session of this page."
  def lock_all, do: run(:vaultLockAll, [])

  @doc "Whether `handle` is still an unlocked session."
  def active?(handle), do: run(:vaultActive, [handle]) == {:ok, "true"}

  @doc """
  Whether the session holds the vault key (may add or replace unlock methods).
  A session opened by a remembered device holds only the document key.
  """
  def can_manage?(handle), do: run(:vaultCanManage, [handle]) == {:ok, "true"}

  # --- documents -----------------------------------------------------------------

  @doc """
  Encrypts the UTF-8 string `plaintext` (AES-256-GCM, fresh random IV, AAD bound
  to `workspace_id` and `revision`). Returns the `"v1..."` envelope.
  """
  def encrypt_document(handle, workspace_id, revision, plaintext),
    do: run(:vaultEncrypt, [handle, workspace_id, revision, plaintext])

  @doc "Inverse of `encrypt_document/4`; any failure is `{:error, :decrypt_failed}`."
  def decrypt_document(handle, workspace_id, revision, envelope),
    do: run(:vaultDecrypt, [handle, workspace_id, revision, envelope])

  # --- new unlock methods (need a session that holds the vault key) -----------------

  @doc """
  Wraps the session's vault key under a NEW passphrase: Argon2id with a fresh
  16-byte salt and the app's floor (64 MiB, 3 passes, 1 lane). Slow by design.
  Returns `{:ok, %{salt: b64u, kdf_params: json_string, wrapped_key: envelope}}`.
  """
  def wrap_passphrase(handle, passphrase, workspace_id, wrap_id) do
    case run(:vaultWrapPassphrase, [handle, passphrase, workspace_id, wrap_id]) do
      {:ok, joined} ->
        case String.split(joined, "|") do
          [salt, kdf, wrapped] -> {:ok, %{salt: salt, kdf_params: kdf, wrapped_key: wrapped}}
          _ -> {:error, :internal}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Generates a NEW recovery key and wraps the session's vault key under it.
  `{:ok, %{recovery_key: text, wrapped_key: envelope}}`; `recovery_key` is 14
  dash-separated groups of 4 base32 characters (52 of key + 4 checksum) and is
  never stored: show it once.
  """
  def wrap_recovery(handle, workspace_id, wrap_id) do
    case run(:vaultWrapRecovery, [handle, workspace_id, wrap_id]) do
      {:ok, joined} ->
        case String.split(joined, "|") do
          [text, wrapped] -> {:ok, %{recovery_key: text, wrapped_key: wrapped}}
          _ -> {:error, :internal}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Creates a passkey (WebAuthn PRF) and wraps the session's vault key under it.
  `opts`: `:rp_id` (`""` = page domain), `:rp_name`, `:user_name`.
  `{:ok, %{credential_id: b64u, wrapped_key: envelope}}`; errors are
  `:passkey_unsupported`, `:passkey_cancelled`, `:passkey_failed`.
  """
  def wrap_passkey(handle, workspace_id, wrap_id, %{
        rp_id: rp_id,
        rp_name: rp_name,
        user_name: user
      }) do
    case run(:vaultWrapPasskey, [handle, workspace_id, wrap_id, rp_id, rp_name, user]) do
      {:ok, joined} ->
        case String.split(joined, "|") do
          [credential_id, wrapped] -> {:ok, %{credential_id: credential_id, wrapped_key: wrapped}}
          _ -> {:error, :internal}
        end

      {:error, _} = error ->
        error
    end
  end

  # --- unlock (open a session from a stored wrap) -------------------------------------

  @doc """
  Unlocks with a passphrase against a stored wrap (`salt`, `kdf_params` JSON and
  `wrapped_key` exactly as the server returned them). The facade bounds-checks
  the stored Argon2 params. Returns `{:ok, handle}`; any wrong secret is
  `{:error, :decrypt_failed}`.
  """
  def unlock_passphrase(passphrase, workspace_id, wrap) do
    run(:vaultUnlockPassphrase, [
      passphrase,
      workspace_id,
      wrap.id,
      wrap.salt,
      wrap.kdf_params,
      wrap.wrapped_key
    ])
  end

  @doc """
  Unlocks with a typed recovery key (case, spaces, dashes ignored). A malformed
  or mistyped key is `{:error, :bad_recovery_key}`; a well-formed wrong key is
  `{:error, :decrypt_failed}`.
  """
  def unlock_recovery(text, workspace_id, wrap),
    do: run(:vaultUnlockRecovery, [text, workspace_id, wrap.id, wrap.wrapped_key])

  @doc "Unlocks with the passkey of `wrap` (WebAuthn `get()` with PRF)."
  def unlock_passkey(workspace_id, rp_id, wrap),
    do:
      run(:vaultUnlockPasskey, [
        wrap.credential_id,
        rp_id,
        workspace_id,
        wrap.id,
        wrap.wrapped_key
      ])

  # --- remember this device ------------------------------------------------------------

  @doc """
  Stores the session's NON-EXTRACTABLE document CryptoKey (encrypt/decrypt only)
  in IndexedDB under the workspace id. Scripts can use it, never read its bytes.
  """
  def remember_device(handle, workspace_id), do: run(:deviceRemember, [handle, workspace_id])

  @doc "Whether a remembered-device key exists for the workspace."
  def device_remembered?(workspace_id), do: run(:deviceHas, [workspace_id]) == {:ok, "true"}

  @doc """
  Opens a session from the remembered key: document encrypt/decrypt only
  (`can_manage?/1` is false). `{:error, :decrypt_failed}` when none is stored.
  """
  def unlock_device(workspace_id), do: run(:deviceUnlock, [workspace_id])

  @doc "Deletes the remembered-device key."
  def forget_device(workspace_id), do: run(:deviceForget, [workspace_id])

  @doc """
  Non-secret per-workspace "locked" marker: set by a manual, idle or cross-tab
  lock so a page load does not silently re-open a remembered device.
  """
  def mark_locked(workspace_id), do: run(:deviceMarkLocked, [workspace_id])

  @doc "Clears the locked marker (explicit device unlock, or a fresh method unlock)."
  def clear_locked(workspace_id), do: run(:deviceClearLocked, [workspace_id])

  @doc "Whether the locked marker is set for the workspace."
  def locked_marker?(workspace_id), do: run(:deviceIsLocked, [workspace_id]) == {:ok, "true"}

  # --- rollback detection ------------------------------------------------------------------

  @doc """
  Compares the server's `revision` / `blob` with the last seen record for the
  workspace: `{:ok, "first" | "ok" | "rollback"}` (rollback = lower revision, or
  the same revision with a different SHA-256).
  """
  def seen_check(workspace_id, revision, blob),
    do: run(:seenCheck, [workspace_id, revision, blob])

  @doc "Records `revision` and the SHA-256 of `blob` as the last seen state."
  def seen_record(workspace_id, revision, blob),
    do: run(:seenRecord, [workspace_id, revision, blob])

  @doc """
  The user explicitly accepted a rollback (or a new vault was created): the
  only call that can lower the last-seen record, which `seen_record/3` never does.
  """
  def seen_acknowledge(workspace_id, revision, blob),
    do: run(:seenAcknowledge, [workspace_id, revision, blob])

  @doc "Deletes every local record (remembered key, last seen state) for the workspace."
  def local_wipe(workspace_id), do: run(:localWipe, [workspace_id])

  # --- internals -----------------------------------------------------------------------------

  # Server side JS interop is a no-op returning :ok; in the browser the call
  # returns a Task for the facade's Promise.
  defp run(function, args) do
    case JS.call(:CryptoFacade, function, args) do
      :ok -> {:error, :not_in_browser}
      task -> task |> Task.await() |> parse()
    end
  end

  defp parse("ok:" <> value), do: {:ok, value}
  defp parse("err:" <> code), do: {:error, error_code(code)}
  defp parse(_), do: {:error, :internal}

  defp error_code("decrypt_failed"), do: :decrypt_failed
  defp error_code("locked"), do: :locked
  defp error_code("bad_input"), do: :bad_input
  defp error_code("bad_params"), do: :bad_params
  defp error_code("bad_recovery_key"), do: :bad_recovery_key
  defp error_code("passkey_unsupported"), do: :passkey_unsupported
  defp error_code("passkey_cancelled"), do: :passkey_cancelled
  defp error_code("passkey_failed"), do: :passkey_failed
  defp error_code("crypto_unavailable"), do: :crypto_unavailable
  defp error_code("selftest_failed"), do: :selftest_failed
  defp error_code(_), do: :internal
end
