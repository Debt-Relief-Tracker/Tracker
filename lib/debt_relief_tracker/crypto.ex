defmodule DebtReliefTracker.Crypto do
  @moduledoc """
  Elixir facade over `assets/js/crypto_facade.mjs`, the browser crypto layer
  for E2EE mode (ADR 0007). The only module that talks to that file.

  No hand-rolled primitives: AES-256-GCM, HKDF-SHA256 and randomness are
  WebCrypto; Argon2id is the bundled `hash-wasm` package; passkeys use the
  WebAuthn PRF extension. Hologram bundles the facade and `hash-wasm` from
  `assets/node_modules` (no CDN). Argon2's WebAssembly needs the
  `'wasm-unsafe-eval'` CSP source; nothing here needs `'unsafe-eval'`.

  ## Contract

  Everything is a string. Binary values (keys, salts, KEKs, credential ids)
  are base64url without padding; documents are UTF-8 strings (typically
  JSON); ciphertext and wraps are `"v1.<iv>.<ciphertext||tag>"` envelopes
  (see the facade header for the AAD layouts).

  Every function returns `{:ok, value}` or `{:error, code}` and never raises
  for crypto failures. Codes: `:decrypt_failed` (one code for wrong key, wrong
  AAD, tampering and malformed input, so there is no oracle), `:bad_input`,
  `:bad_params`, `:bad_recovery_key`, `:passkey_unsupported`,
  `:passkey_cancelled`, `:passkey_failed`, `:crypto_unavailable`,
  `:selftest_failed`, `:internal`, and `:not_in_browser` (called on the
  server, where Hologram JS interop is a no-op).

  The JS functions are async (Promises become Elixir Tasks), so these must be
  called from a Hologram action, which awaits them; a call blocks that
  component's later actions until it finishes. Argon2id at 64 MiB takes
  seconds, so put the UI in a "working" state first and chain the derive in a
  separate action.

  Never log or store the returned keys, passphrases, plaintext or ciphertext
  outside the intended places.
  """

  use Hologram.JS

  js_import from: "../../assets/js/crypto_facade.mjs", as: :CryptoFacade

  @type result(t) :: {:ok, t} | {:error, atom()}
  @type kind :: :passphrase | :passkey | :recovery
  @type argon2_params :: %{
          memory_kib: pos_integer(),
          iterations: pos_integer(),
          parallelism: pos_integer()
        }

  @doc """
  Argon2id parameters to start new passphrase wraps with (64 MiB, 3 passes,
  1 lane). Store the params used next to each wrap and pass them back to
  `derive_passphrase_kek/3`; they are never defaulted at unwrap time. The
  facade rejects stored params above 1 GiB, 20 passes or 16 lanes.
  """
  def default_argon2_params, do: %{memory_kib: 65_536, iterations: 3, parallelism: 1}

  # --- randomness / hashing -------------------------------------------------

  @doc "`n` random bytes (1..65536) from `crypto.getRandomValues`, base64url."
  def random_bytes(n), do: run(:randomBytesB64u, [n])

  @doc "SHA-256 of the UTF-8 string `string`, base64url."
  def sha256(string), do: run(:sha256B64u, [string])

  @doc "A new 32-byte vault key (VK), base64url."
  def generate_vault_key, do: run(:generateVaultKey, [])

  @doc "A fresh 16-byte Argon2 salt, base64url."
  def new_salt, do: run(:newSaltB64u, [])

  # --- documents -------------------------------------------------------------

  @doc """
  Encrypts the UTF-8 string `plaintext` under `vault_key` (base64url) with
  AES-256-GCM, a fresh random 12-byte IV, and AAD bound to `workspace_id`
  (non-empty string) and `revision` (non-negative integer). Returns the
  `"v1.<iv>.<ct||tag>"` envelope.
  """
  def encrypt_document(vault_key, workspace_id, revision, plaintext),
    do: run(:encryptDocument, [vault_key, workspace_id, revision, plaintext])

  @doc """
  Inverse of `encrypt_document/4`. Any failure (wrong key, workspace or
  revision, tampering, malformed envelope) is `{:error, :decrypt_failed}`.
  """
  def decrypt_document(vault_key, workspace_id, revision, envelope),
    do: run(:decryptDocument, [vault_key, workspace_id, revision, envelope])

  # --- key wraps ---------------------------------------------------------------

  @doc """
  Wraps `vault_key` under `kek` (both base64url, 32 bytes) with AES-256-GCM,
  a fresh IV and AAD bound to `workspace_id`, `wrap_id` and `kind`
  (`:passphrase | :passkey | :recovery`). Returns a `"v1..."` envelope.
  """
  def wrap_vault_key(kek, vault_key, workspace_id, wrap_id, kind),
    do: run(:wrapVaultKey, [kek, vault_key, workspace_id, wrap_id, kind_string(kind)])

  @doc """
  Unwraps to the vault key (base64url). Any failure, including a wrong
  `kind`/`wrap_id`/`workspace_id`, is `{:error, :decrypt_failed}`.
  """
  def unwrap_vault_key(kek, wrap_envelope, workspace_id, wrap_id, kind),
    do: run(:unwrapVaultKey, [kek, wrap_envelope, workspace_id, wrap_id, kind_string(kind)])

  # --- passphrase ---------------------------------------------------------------

  @doc """
  Unwrap-time passphrase KEK (base64url) = Argon2id(NFKC(passphrase) as UTF-8,
  `salt`) with the STORED `params` (see `default_argon2_params/0`), 32-byte
  output. `salt` is base64url. Accepts any params within the sanity bounds
  (at most 1 GiB, 20 passes, 16 lanes; at least Argon2's own minimums): a
  malicious server can only make unwrap fail by lowering them, and the
  passphrase never leaves the browser. Do NOT use this for a wrap you write;
  use `derive_new_passphrase_kek/3`. Slow by design.
  """
  def derive_passphrase_kek(passphrase, salt, params),
    do: derive(:derivePassphraseKek, passphrase, salt, params)

  @doc """
  Creation-time passphrase KEK, for every wrap the app writes (new wrap or
  re-wrap). Same as `derive_passphrase_kek/3` but returns `{:error,
  :bad_params}` for memory below 65536 KiB, fewer than 3 iterations or a salt
  under 16 bytes, so weak params can never be created.
  """
  def derive_new_passphrase_kek(passphrase, salt, params),
    do: derive(:deriveNewPassphraseKek, passphrase, salt, params)

  defp derive(function, passphrase, salt, %{
         memory_kib: memory_kib,
         iterations: iterations,
         parallelism: parallelism
       }),
       do: run(function, [passphrase, salt, memory_kib, iterations, parallelism])

  # --- recovery key ---------------------------------------------------------------

  @doc """
  A new 256-bit recovery key as grouped base32 (RFC 4648 alphabet, no
  padding): 52 characters of key plus a 4-character checksum (first 20 bits
  of SHA-256("drt-recovery-check-v1" || key bytes)), shown as 14
  dash-separated groups of 4. Show it once; it is never stored by the app.
  """
  def generate_recovery_key, do: run(:generateRecoveryKey, [])

  @doc """
  Parses a recovery key typed by a human (case, spaces and dashes are
  ignored) to its 32 raw bytes, base64url. Wrong length, bad characters or a
  bad checksum are `{:error, :bad_recovery_key}` (a typo), distinct from a
  correct-looking but wrong key, which later fails as `:decrypt_failed`.
  """
  def parse_recovery_key(text), do: run(:parseRecoveryKey, [text])

  @doc "Canonical grouped display form (with checksum) of 32 raw recovery-key bytes (base64url)."
  def format_recovery_key(raw), do: run(:formatRecoveryKey, [raw])

  @doc """
  Recovery KEK (base64url) from the human-entered recovery key text:
  HKDF-SHA256(key bytes, empty salt, info `"drt-kek-v1"`).
  """
  def derive_recovery_kek(text), do: run(:deriveRecoveryKek, [text])

  # --- passkey (WebAuthn PRF) --------------------------------------------------------

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

  @doc """
  Creates a passkey with the PRF extension and derives its KEK, running an
  immediate `get()` if the create result carries no PRF output. `opts` is a
  map with string values: `:rp_id` (`""` = page domain), `:rp_name`,
  `:user_id` (base64url, 1..64 bytes), `:user_name`, `:display_name`.
  Returns `{:ok, %{credential_id: b64u, kek: b64u}}`; errors are
  `:passkey_unsupported`, `:passkey_cancelled` or `:passkey_failed`.
  """
  def create_passkey(%{
        rp_id: rp_id,
        rp_name: rp_name,
        user_id: user_id,
        user_name: user_name,
        display_name: display_name
      }) do
    case run(:createPasskey, [rp_id, rp_name, user_id, user_name, display_name]) do
      {:ok, joined} ->
        case String.split(joined, ".") do
          [credential_id, kek] -> {:ok, %{credential_id: credential_id, kek: kek}}
          _ -> {:error, :internal}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Passkey KEK (base64url) via `get()` with the PRF extension on `credential_id`."
  def derive_passkey_kek(credential_id, rp_id),
    do: run(:derivePasskeyKek, [credential_id, rp_id])

  # --- self test -----------------------------------------------------------------------

  @doc "Runs the facade's known-answer checks; `{:ok, \"ok\"}` or `{:error, :selftest_failed}`."
  def self_test, do: run(:selfTest, [])

  # --- internals -------------------------------------------------------------------------

  defp kind_string(:passphrase), do: "passphrase"
  defp kind_string(:passkey), do: "passkey"
  defp kind_string(:recovery), do: "recovery"
  defp kind_string(other), do: other

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
