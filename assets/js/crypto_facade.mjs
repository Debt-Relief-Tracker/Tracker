// Browser crypto facade for the E2EE mode (docs/architecture/0007-e2ee.md).
// Called through DebtReliefTracker.Crypto -- never directly from app code.
//
// NO hand-rolled primitives. AES-256-GCM, HKDF-SHA256, SHA-256 and randomness
// come from WebCrypto (crypto.subtle / crypto.getRandomValues); Argon2id comes
// from the `hash-wasm` npm package (bundled locally, WebAssembly, no CDN).
//
// Contract: every public function takes and returns STRINGS ONLY (Hologram
// interop turns typed arrays into opaque values). Binary is base64url without
// padding ("b64u"); structured values are joined with "." (b64u never contains
// "."). Nothing here logs; no secret is written to storage, cookies or URLs;
// derived keys live only in local variables for the duration of one call.
//
// Two surfaces:
//   * named exports  -- Promise-returning, THROW CryptoError(code) on failure
//                       (used by the Node tests and by other JS);
//   * default export -- the same public functions, each wrapped so it never
//                       throws and resolves to "ok:<value>" or "err:<code>"
//                       (used by Hologram; DebtReliefTracker.Crypto parses it).
//
// ENVELOPE (document ciphertext and key wraps), version 1:
//
//     v1.<iv_b64u>.<ct_b64u>
//
//   iv  = 12 random bytes, fresh for EVERY encryption (never a counter)
//   ct  = AES-256-GCM ciphertext || 16-byte (128-bit) tag
//
// AAD (authenticated, not transmitted; the caller supplies the context):
//   document: "drt-vault-v1" 0x00 workspaceId 0x00 String(revision)
//   wrap:     "drt-wrap-v1"  0x00 workspaceId 0x00 wrapId 0x00 kind
//   kind in passphrase | passkey | recovery
//
// ERROR CODES (the only strings an "err:" result can carry):
//   decrypt_failed     any decrypt/unwrap failure: wrong key, wrong AAD,
//                      tampering, malformed/truncated envelope. ONE code, so
//                      there is no oracle between those cases.
//   bad_input          caller passed an invalid argument (not secret-dependent)
//   bad_params         Argon2 params outside the accepted range
//   bad_recovery_key   recovery key text has wrong length/characters
//   passkey_unsupported  no WebAuthn / no PRF support
//   passkey_cancelled  user dismissed or timed out the prompt
//   passkey_failed     any other passkey failure
//   locked             the session handle is unknown (locked / never unlocked)
//   crypto_unavailable WebCrypto missing (e.g. insecure context)
//   selftest_failed    selfTest() KAT mismatch
//   internal           anything unexpected (message is never included)
import { argon2id } from "hash-wasm"
import * as store from "./vault_store.mjs"

export class CryptoError extends Error {
  constructor(code) {
    super(code)
    this.name = "CryptoError"
    this.code = code
  }
}

const ENVELOPE_VERSION = "v1"
const IV_BYTES = 12
const TAG_BYTES = 16
const KEY_BYTES = 32
const SALT_BYTES = 16
const KINDS = ["passphrase", "passkey", "recovery"]
const VAULT_AAD_TAG = "drt-vault-v1"
const WRAP_AAD_TAG = "drt-wrap-v1"
const KEK_INFO = "drt-kek-v1"
const PRF_SALT_LABEL = "drt-prf-salt-v1"

// Accepted Argon2id parameter range (stored params are honoured, absurd ones
// rejected so a malicious server cannot make the client allocate gigabytes).
export const ARGON2_LIMITS = { maxMemoryKiB: 1048576, maxIterations: 20, maxParallelism: 16 }
// Starting params for new passphrase wraps; callers store them with the wrap.
export const ARGON2_DEFAULTS = { memoryKiB: 65536, iterations: 3, parallelism: 1 }

const enc = new TextEncoder()
const dec = new TextDecoder("utf-8", { fatal: true })

function subtle() {
  const c = globalThis.crypto
  if (!c || !c.subtle || !c.getRandomValues) throw new CryptoError("crypto_unavailable")
  return c
}

// ---- encoding -------------------------------------------------------------

const B64U = /^[A-Za-z0-9_-]*$/

export function bytesToB64u(bytes) {
  let s = ""
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000))
  }
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

// Strict: unpadded base64url only, canonical (no stray trailing bits).
export function b64uToBytes(str) {
  if (typeof str !== "string" || !B64U.test(str) || str.length % 4 === 1) {
    throw new CryptoError("bad_input")
  }
  const b64 = str.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((str.length + 3) % 4)
  let bin
  try {
    bin = atob(b64)
  } catch {
    throw new CryptoError("bad_input")
  }
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  if (bytesToB64u(out) !== str) throw new CryptoError("bad_input")
  return out
}

function utf8(str) {
  if (typeof str !== "string") throw new CryptoError("bad_input")
  return enc.encode(str)
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) {
    out.set(p, o)
    o += p.length
  }
  return out
}

// ---- randomness / hashing -------------------------------------------------

export async function randomBytesB64u(n) {
  const len = Number(n)
  if (!Number.isInteger(len) || len < 1 || len > 65536) throw new CryptoError("bad_input")
  const out = new Uint8Array(len)
  subtle().getRandomValues(out)
  return bytesToB64u(out)
}

// SHA-256 of a UTF-8 string, as b64u.
export async function sha256B64u(str) {
  const digest = await subtle().subtle.digest("SHA-256", utf8(str))
  return bytesToB64u(new Uint8Array(digest))
}

function freshIv() {
  const iv = new Uint8Array(IV_BYTES)
  subtle().getRandomValues(iv)
  return iv
}

// ---- HKDF -----------------------------------------------------------------

async function hkdfBytes(ikm, salt, info, length) {
  const { subtle: s } = subtle()
  const key = await s.importKey("raw", ikm, "HKDF", false, ["deriveBits"])
  const bits = await s.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, length * 8)
  return new Uint8Array(bits)
}

// General HKDF-SHA256 (RFC 5869). Inputs/outputs b64u; salt "" = empty salt.
export async function hkdfSha256B64u(ikmB64u, saltB64u, infoB64u, length) {
  const len = Number(length)
  if (!Number.isInteger(len) || len < 1 || len > 255 * 32) throw new CryptoError("bad_input")
  const out = await hkdfBytes(b64uToBytes(ikmB64u), b64uToBytes(saltB64u), b64uToBytes(infoB64u), len)
  return bytesToB64u(out)
}

// IKM bytes -> 32-byte KEK: HKDF-SHA256(ikm, salt = empty, info = "drt-kek-v1").
async function kekFromIkm(ikm) {
  return hkdfBytes(ikm, new Uint8Array(0), enc.encode(KEK_INFO), KEY_BYTES)
}

// ---- AES-256-GCM ----------------------------------------------------------

async function importAesKey(keyBytes, usage) {
  if (keyBytes.length !== KEY_BYTES) throw new CryptoError("bad_input")
  return subtle().subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, [usage])
}

function envelope(iv, ct) {
  return `${ENVELOPE_VERSION}.${bytesToB64u(iv)}.${bytesToB64u(ct)}`
}

// Returns {iv, ct} or null for anything malformed (callers map to the one
// generic error). Never distinguishes why.
function parseEnvelope(str) {
  if (typeof str !== "string") return null
  const parts = str.split(".")
  if (parts.length !== 3 || parts[0] !== ENVELOPE_VERSION) return null
  try {
    const iv = b64uToBytes(parts[1])
    const ct = b64uToBytes(parts[2])
    if (iv.length !== IV_BYTES || ct.length < TAG_BYTES) return null
    return { iv, ct }
  } catch {
    return null
  }
}

// Encrypt with a FRESH random IV drawn inside this call -- the only way the
// public API encrypts, so an IV can never be chosen, reused or counted by a
// caller. (Random 96-bit IVs are safe up to ~2^32 messages per key; a vault
// key encrypts one document per revision, so the bound is not approachable.)
export async function encryptFresh(keyBytes, plaintextBytes, aadBytes) {
  const key = await importAesKey(keyBytes, "encrypt")
  const iv = freshIv()
  const ct = await subtle().subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: aadBytes, tagLength: 128 },
    key,
    plaintextBytes,
  )
  return envelope(iv, new Uint8Array(ct))
}

// Any failure -> the single generic error.
async function decryptEnvelope(keyBytes, env, aadBytes) {
  const parsed = parseEnvelope(env)
  if (!parsed || keyBytes.length !== KEY_BYTES) throw new CryptoError("decrypt_failed")
  try {
    const key = await importAesKey(keyBytes, "decrypt")
    const pt = await subtle().subtle.decrypt(
      { name: "AES-GCM", iv: parsed.iv, additionalData: aadBytes, tagLength: 128 },
      key,
      parsed.ct,
    )
    return new Uint8Array(pt)
  } catch {
    throw new CryptoError("decrypt_failed")
  }
}

// TEST/SELF-TEST ONLY: deterministic IV for known-answer vectors. Not part of
// the default (Hologram) export; never call with a real key.
export async function __testOnlyEncryptWithIv(keyB64u, ivB64u, ptB64u, aadB64u) {
  const key = await importAesKey(b64uToBytes(keyB64u), "encrypt")
  const ct = await subtle().subtle.encrypt(
    { name: "AES-GCM", iv: b64uToBytes(ivB64u), additionalData: b64uToBytes(aadB64u), tagLength: 128 },
    key,
    b64uToBytes(ptB64u),
  )
  return bytesToB64u(new Uint8Array(ct))
}

// ---- AAD ------------------------------------------------------------------

function idPart(value) {
  const s = typeof value === "number" ? String(value) : value
  if (typeof s !== "string" || s.length === 0 || s.includes("\u0000")) throw new CryptoError("bad_input")
  return enc.encode(s)
}

function vaultAad(workspaceId, revision) {
  const rev = typeof revision === "string" && /^(0|[1-9][0-9]*)$/.test(revision) ? Number(revision) : revision
  if (!Number.isSafeInteger(rev) || rev < 0) throw new CryptoError("bad_input")
  return concat(enc.encode(VAULT_AAD_TAG), Uint8Array.of(0), idPart(workspaceId), Uint8Array.of(0), enc.encode(String(rev)))
}

function wrapAad(workspaceId, wrapId, kind) {
  if (!KINDS.includes(kind)) throw new CryptoError("bad_input")
  return concat(
    enc.encode(WRAP_AAD_TAG),
    Uint8Array.of(0),
    idPart(workspaceId),
    Uint8Array.of(0),
    idPart(wrapId),
    Uint8Array.of(0),
    enc.encode(kind),
  )
}

// ---- vault key + document -------------------------------------------------

// Fresh 32-byte vault key from getRandomValues, as b64u.
export async function generateVaultKey() {
  return randomBytesB64u(KEY_BYTES)
}

// plaintext: JS string (UTF-8). Returns the v1 envelope.
export async function encryptDocument(vkB64u, workspaceId, revision, plaintext) {
  const vk = b64uToBytes(vkB64u)
  return encryptFresh(vk, utf8(plaintext), vaultAad(workspaceId, revision))
}

// Returns the plaintext string; throws decrypt_failed on ANY failure.
export async function decryptDocument(vkB64u, workspaceId, revision, envelopeStr) {
  const vk = b64uToBytes(vkB64u)
  const aad = vaultAad(workspaceId, revision)
  const pt = await decryptEnvelope(vk, envelopeStr, aad)
  try {
    return dec.decode(pt)
  } catch {
    throw new CryptoError("decrypt_failed")
  }
}

// ---- key wrap -------------------------------------------------------------

export async function wrapVaultKey(kekB64u, vkB64u, workspaceId, wrapId, kind) {
  const kek = b64uToBytes(kekB64u)
  const vk = b64uToBytes(vkB64u)
  if (vk.length !== KEY_BYTES) throw new CryptoError("bad_input")
  return encryptFresh(kek, vk, wrapAad(workspaceId, wrapId, kind))
}

// Returns the vault key (b64u); throws decrypt_failed on ANY failure.
export async function unwrapVaultKey(kekB64u, wrapEnvelope, workspaceId, wrapId, kind) {
  const kek = b64uToBytes(kekB64u)
  const vk = await decryptEnvelope(kek, wrapEnvelope, wrapAad(workspaceId, wrapId, kind))
  if (vk.length !== KEY_BYTES) throw new CryptoError("decrypt_failed")
  return bytesToB64u(vk)
}

// ---- passphrase KEK (Argon2id) ---------------------------------------------

export async function newSaltB64u() {
  return randomBytesB64u(SALT_BYTES)
}

function checkArgon2Params(memoryKiB, iterations, parallelism, saltLen) {
  const ok = (v) => Number.isInteger(v) && v >= 1
  if (!ok(memoryKiB) || !ok(iterations) || !ok(parallelism)) throw new CryptoError("bad_params")
  if (
    memoryKiB > ARGON2_LIMITS.maxMemoryKiB ||
    iterations > ARGON2_LIMITS.maxIterations ||
    parallelism > ARGON2_LIMITS.maxParallelism ||
    memoryKiB < 8 * parallelism ||
    saltLen < 8
  ) {
    throw new CryptoError("bad_params")
  }
}

// Argon2id(NFKC(passphrase) as UTF-8, salt) -> 32 raw bytes. Parameters are
// explicit arguments (stored by the caller with each wrap); no hidden defaults.
export async function argon2idRaw(passwordBytes, saltBytes, memoryKiB, iterations, parallelism, length = KEY_BYTES) {
  checkArgon2Params(memoryKiB, iterations, parallelism, saltBytes.length)
  return argon2id({
    password: passwordBytes,
    salt: saltBytes,
    iterations,
    parallelism,
    memorySize: memoryKiB,
    hashLength: length,
    outputType: "binary",
  })
}

// KEK (b64u) from a passphrase. memoryKiB/iterations/parallelism may be
// numbers or numeric strings.
export async function derivePassphraseKek(passphrase, saltB64u, memoryKiB, iterations, parallelism) {
  if (typeof passphrase !== "string" || passphrase.length === 0) throw new CryptoError("bad_input")
  const salt = b64uToBytes(saltB64u)
  const out = await argon2idRaw(
    enc.encode(passphrase.normalize("NFKC")),
    salt,
    Number(memoryKiB),
    Number(iterations),
    Number(parallelism),
  )
  return bytesToB64u(out)
}

// Creation-time entry point: the ONLY function the app should use for any
// wrap it writes (new wrap or re-wrap). Enforces a floor on top of the sanity
// bounds; unwrap-time derivePassphraseKek honours stored params instead (a
// malicious server can only make unwrap fail by lowering them; the
// passphrase never leaves the browser).
export const ARGON2_FLOOR = { memoryKiB: 65536, iterations: 3, saltBytes: 16 }

export async function deriveNewPassphraseKek(passphrase, saltB64u, memoryKiB, iterations, parallelism) {
  const salt = b64uToBytes(saltB64u)
  if (
    Number(memoryKiB) < ARGON2_FLOOR.memoryKiB ||
    Number(iterations) < ARGON2_FLOOR.iterations ||
    salt.length < ARGON2_FLOOR.saltBytes
  ) {
    throw new CryptoError("bad_params")
  }
  return derivePassphraseKek(passphrase, saltB64u, memoryKiB, iterations, parallelism)
}

// ---- recovery key ----------------------------------------------------------

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
const RECOVERY_BYTES = 32
const RECOVERY_CHARS = 52 // ceil(256 / 5); the last char carries 4 zero pad bits
const RECOVERY_CHECK_CHARS = 4
const RECOVERY_CHECK_LABEL = "drt-recovery-check-v1"

export function base32Encode(bytes) {
  let out = ""
  let bits = 0
  let acc = 0
  for (const b of bytes) {
    acc = (acc << 8) | b
    bits += 8
    while (bits >= 5) {
      out += B32[(acc >>> (bits - 5)) & 31]
      bits -= 5
    }
    acc &= (1 << bits) - 1
  }
  if (bits > 0) out += B32[(acc << (5 - bits)) & 31]
  return out
}

// Strict decode of an unpadded RFC 4648 base32 string (uppercase). Rejects bad
// characters and non-zero trailing bits (non-canonical).
export function base32Decode(str) {
  const out = []
  let bits = 0
  let acc = 0
  for (const ch of str) {
    const v = B32.indexOf(ch)
    if (v < 0) throw new CryptoError("bad_recovery_key")
    acc = (acc << 5) | v
    bits += 5
    if (bits >= 8) {
      out.push((acc >>> (bits - 8)) & 255)
      bits -= 8
    }
    acc &= (1 << bits) - 1
  }
  if (acc !== 0) throw new CryptoError("bad_recovery_key")
  return Uint8Array.from(out)
}

function groupFive(s) {
  return s.match(/.{1,4}/g).join("-")
}

// Checksum: first 20 bits of SHA-256("drt-recovery-check-v1" || keyBytes) as
// 4 base32 chars (20 bits = exactly 4 chars, no padding bits).
async function recoveryChecksum(keyBytes) {
  const d = await subtle().subtle.digest("SHA-256", concat(enc.encode(RECOVERY_CHECK_LABEL), keyBytes))
  return base32Encode(new Uint8Array(d).subarray(0, 3)).slice(0, 4)
}

async function formatRecoveryBytes(bytes) {
  return groupFive(base32Encode(bytes) + (await recoveryChecksum(bytes)))
}

// New 256-bit recovery key shown as 14 dash-separated groups of 4 base32 chars:
// 52 chars of key + 4 chars of checksum (56 total).
export async function generateRecoveryKey() {
  const bytes = new Uint8Array(RECOVERY_BYTES)
  subtle().getRandomValues(bytes)
  return formatRecoveryBytes(bytes)
}

async function parseRecoveryBytes(text) {
  if (typeof text !== "string") throw new CryptoError("bad_recovery_key")
  const clean = text.replace(/[\s-]+/g, "").toUpperCase()
  if (clean.length !== RECOVERY_CHARS + RECOVERY_CHECK_CHARS) throw new CryptoError("bad_recovery_key")
  const bytes = base32Decode(clean.slice(0, RECOVERY_CHARS))
  if (bytes.length !== RECOVERY_BYTES) throw new CryptoError("bad_recovery_key")
  if (clean.slice(RECOVERY_CHARS) !== (await recoveryChecksum(bytes))) throw new CryptoError("bad_recovery_key")
  return bytes
}

// Tolerant of case, spaces, dashes. Requires length 56 and a valid checksum
// (so a typo is bad_recovery_key, distinct from a wrong key = decrypt_failed).
// Returns the 32 raw key bytes as b64u.
export async function parseRecoveryKey(text) {
  return bytesToB64u(await parseRecoveryBytes(text))
}

// Canonical grouped display form (with checksum) of 32 raw key bytes (b64u).
export async function formatRecoveryKey(rawB64u) {
  const bytes = b64uToBytes(rawB64u)
  if (bytes.length !== RECOVERY_BYTES) throw new CryptoError("bad_input")
  return formatRecoveryBytes(bytes)
}

// KEK (b64u) = HKDF-SHA256(recovery key bytes, salt empty, info "drt-kek-v1").
export async function deriveRecoveryKek(recoveryText) {
  return bytesToB64u(await kekFromIkm(await parseRecoveryBytes(recoveryText)))
}

// ---- passkey (WebAuthn PRF) -------------------------------------------------

async function prfSaltBytes() {
  const d = await subtle().subtle.digest("SHA-256", enc.encode(PRF_SALT_LABEL))
  return new Uint8Array(d)
}

// Feature detection. True means "WebAuthn exists and nothing says PRF is
// unavailable"; actual PRF support is only confirmed when a credential is made.
export async function prfSupported() {
  try {
    const PKC = globalThis.PublicKeyCredential
    if (!PKC || !globalThis.navigator || !globalThis.navigator.credentials) return false
    if (globalThis.isSecureContext === false) return false
    if (typeof PKC.getClientCapabilities === "function") {
      const caps = await PKC.getClientCapabilities()
      if (caps && caps["extension:prf"] === false) return false
    }
    return true
  } catch {
    return false
  }
}

function mapPasskeyError(e) {
  if (e instanceof CryptoError) return e
  const name = e && e.name
  if (name === "NotAllowedError" || name === "AbortError") return new CryptoError("passkey_cancelled")
  if (name === "NotSupportedError") return new CryptoError("passkey_unsupported")
  return new CryptoError("passkey_failed")
}

function prfFirst(credential) {
  const ext = credential.getClientExtensionResults ? credential.getClientExtensionResults() : {}
  const first = ext && ext.prf && ext.prf.results && ext.prf.results.first
  if (!first) return null
  const bytes = new Uint8Array(first instanceof ArrayBuffer ? first : first.buffer.slice(first.byteOffset, first.byteOffset + first.byteLength))
  return bytes.length === 32 ? bytes : null
}

async function prfGet(credIdBytes, rpId) {
  const cred = await navigator.credentials.get({
    publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      rpId,
      allowCredentials: [{ type: "public-key", id: credIdBytes }],
      userVerification: "preferred",
      timeout: 120000,
      extensions: { prf: { eval: { first: await prfSaltBytes() } } },
    },
  })
  if (!cred) throw new CryptoError("passkey_failed")
  const out = prfFirst(cred)
  if (!out) throw new CryptoError("passkey_unsupported")
  return out
}

// Creates a passkey with the PRF extension and returns "<credId>.<kek>" (both
// b64u). If the create result carries no PRF output (some authenticators only
// return it on get), immediately runs a get() with prf.eval. rpId may be "" to
// use the page's effective domain.
export async function createPasskey(rpId, rpName, userIdB64u, userName, userDisplayName) {
  if (!(await prfSupported())) throw new CryptoError("passkey_unsupported")
  const userId = b64uToBytes(userIdB64u)
  if (userId.length < 1 || userId.length > 64) throw new CryptoError("bad_input")
  let ikm = null
  try {
    const cred = await navigator.credentials.create({
      publicKey: {
        rp: rpId ? { id: rpId, name: rpName || rpId } : { name: rpName || "Debt Relief Tracker" },
        user: { id: userId, name: userName || "user", displayName: userDisplayName || userName || "user" },
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        pubKeyCredParams: [
          { type: "public-key", alg: -7 },
          { type: "public-key", alg: -257 },
        ],
        authenticatorSelection: { residentKey: "preferred", userVerification: "preferred" },
        attestation: "none",
        timeout: 120000,
        extensions: { prf: { eval: { first: await prfSaltBytes() } } },
      },
    })
    if (!cred) throw new CryptoError("passkey_failed")
    const ext = cred.getClientExtensionResults ? cred.getClientExtensionResults() : {}
    if (!ext || !ext.prf || ext.prf.enabled === false) throw new CryptoError("passkey_unsupported")
    const credId = new Uint8Array(cred.rawId)
    ikm = prfFirst(cred)
    if (!ikm) ikm = await prfGet(credId, rpId || undefined)
    const kek = await kekFromIkm(ikm)
    return `${bytesToB64u(credId)}.${bytesToB64u(kek)}`
  } catch (e) {
    throw mapPasskeyError(e)
  }
}

// get() with prf.eval on an existing credential; returns the KEK (b64u).
export async function derivePasskeyKek(credentialIdB64u, rpId) {
  if (!(await prfSupported())) throw new CryptoError("passkey_unsupported")
  const credId = b64uToBytes(credentialIdB64u)
  try {
    const ikm = await prfGet(credId, rpId || undefined)
    return bytesToB64u(await kekFromIkm(ikm))
  } catch (e) {
    throw mapPasskeyError(e)
  }
}

// ---- self test --------------------------------------------------------------

const hex = (h) => Uint8Array.from(h.match(/../g) || [], (b) => parseInt(b, 16))
const toHex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")

// Known-answer checks, cheap enough for startup (Argon2 uses 32 KiB). Resolves
// "ok" or throws CryptoError("selftest_failed") whose .failed lists names.
export async function selfTest() {
  const failed = []
  const check = async (name, fn) => {
    try {
      if (!(await fn())) failed.push(name)
    } catch {
      failed.push(name)
    }
  }

  // McGrew-Viega GCM test case 16 (AES-256 key, 96-bit IV, with AAD):

  await check("aes-256-gcm-kat", async () => {
    const key = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
    const iv = hex("cafebabefacedbaddecaf888")
    const pt = hex(
      "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39",
    )
    const aad = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
    const expect =
      "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662" +
      "76fc6ece0f4e1768cddf8853bb2d551b"
    const got = await __testOnlyEncryptWithIv(
      bytesToB64u(key),
      bytesToB64u(iv),
      bytesToB64u(pt),
      bytesToB64u(aad),
    )
    return toHex(b64uToBytes(got)) === expect
  })

  // RFC 5869 test case 1.
  await check("hkdf-sha256-rfc5869-1", async () => {
    const out = await hkdfSha256B64u(
      bytesToB64u(hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")),
      bytesToB64u(hex("000102030405060708090a0b0c")),
      bytesToB64u(hex("f0f1f2f3f4f5f6f7f8f9")),
      42,
    )
    return (
      toHex(b64uToBytes(out)) ===
      "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
    )
  })

  await check("sha256-abc", async () => {
    const out = await sha256B64u("abc")
    return toHex(b64uToBytes(out)) === "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  })

  await check("base32-rfc4648", async () => {
    return base32Encode(enc.encode("foobar")) === "MZXW6YTBOI"
  })

  // Argon2id, m=32 KiB t=3 p=4, password 32x 0x01, salt 16x 0x02 (RFC 9106
  // section 5.3 shape, without secret/AD, which hash-wasm cannot express);
  // value cross-checked against Node's independent OpenSSL implementation.
  await check("argon2id-kat", async () => {
    const out = await argon2id({
      password: new Uint8Array(32).fill(1),
      salt: new Uint8Array(16).fill(2),
      iterations: 3,
      parallelism: 4,
      memorySize: 32,
      hashLength: 32,
      outputType: "hex",
    })
    return out === ARGON2_SELFTEST_EXPECTED
  })

  if (failed.length) {
    const e = new CryptoError("selftest_failed")
    e.failed = failed
    throw e
  }
  return "ok"
}

const ARGON2_SELFTEST_EXPECTED = "03aab965c12001c9d7d0d2de33192c0494b684bb148196d73c1df1acaf6d0c2e"

// ---- vault sessions (OPAQUE HANDLES) ----------------------------------------
//
// The E2EE UI never sees key material. An unlocked vault lives here, in
// module-private memory: the vault key bytes (`vk`, absent for a "remembered
// device" session) and a NON-EXTRACTABLE AES-GCM CryptoKey derived from it.
// Elixir holds only an opaque handle id (random, meaningless) and passes
// ciphertext envelopes, workspace ids and revisions. Locking overwrites the
// key bytes and drops the entry. Nothing here is written to storage except the
// non-extractable CryptoKey of "remember this device" (vault_store.mjs).
//
// Multi-value results are joined with "|" (never in b64u, envelopes or the
// kdf JSON) so Elixir can split them without parsing JSON.

const sessions = new Map()

function newHandle() {
  const b = new Uint8Array(12)
  subtle().getRandomValues(b)
  return "h" + bytesToB64u(b)
}

async function openSession(vkBytes) {
  const docKey = await subtle().subtle.importKey("raw", vkBytes, { name: "AES-GCM" }, false, ["encrypt", "decrypt"])
  const handle = newHandle()
  sessions.set(handle, { vk: vkBytes, docKey })
  return handle
}

function sessionOf(handle) {
  const s = typeof handle === "string" ? sessions.get(handle) : null
  if (!s) throw new CryptoError("locked")
  return s
}

function vkOf(handle) {
  const s = sessionOf(handle)
  if (!s.vk) throw new CryptoError("locked")
  return s.vk
}

const KDF_PARAMS_JSON = JSON.stringify({
  memoryKiB: ARGON2_DEFAULTS.memoryKiB,
  iterations: ARGON2_DEFAULTS.iterations,
  parallelism: ARGON2_DEFAULTS.parallelism,
})

// New random vault key, unlocked under a fresh handle.
export async function vaultNew() {
  const vk = new Uint8Array(KEY_BYTES)
  subtle().getRandomValues(vk)
  return openSession(vk)
}

export async function vaultLock(handle) {
  const s = sessions.get(handle)
  if (s && s.vk) s.vk.fill(0)
  sessions.delete(handle)
  return "locked"
}

export async function vaultLockAll() {
  for (const s of sessions.values()) if (s.vk) s.vk.fill(0)
  sessions.clear()
  return "locked"
}

export async function vaultActive(handle) {
  return String(sessions.has(handle))
}

// Whether the session can add/replace unlock methods (needs the vault key; a
// "remembered device" session only has the document CryptoKey).
export async function vaultCanManage(handle) {
  const s = sessions.get(handle)
  return String(!!(s && s.vk))
}

export async function vaultEncrypt(handle, workspaceId, revision, plaintext) {
  const { docKey } = sessionOf(handle)
  const iv = freshIv()
  const ct = await subtle().subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: vaultAad(workspaceId, revision), tagLength: 128 },
    docKey,
    utf8(plaintext),
  )
  return envelope(iv, new Uint8Array(ct))
}

export async function vaultDecrypt(handle, workspaceId, revision, envelopeStr) {
  const { docKey } = sessionOf(handle)
  const parsed = parseEnvelope(envelopeStr)
  const aad = vaultAad(workspaceId, revision)
  if (!parsed) throw new CryptoError("decrypt_failed")
  try {
    const pt = await subtle().subtle.decrypt(
      { name: "AES-GCM", iv: parsed.iv, additionalData: aad, tagLength: 128 },
      docKey,
      parsed.ct,
    )
    return dec.decode(pt)
  } catch {
    throw new CryptoError("decrypt_failed")
  }
}

// "<salt>|<kdf params json>|<wrapped key>" for a NEW passphrase wrap (floor on
// Argon2 params enforced by deriveNewPassphraseKek).
export async function vaultWrapPassphrase(handle, passphrase, workspaceId, wrapId) {
  const vk = vkOf(handle)
  const salt = await newSaltB64u()
  const kek = b64uToBytes(
    await deriveNewPassphraseKek(
      passphrase,
      salt,
      ARGON2_DEFAULTS.memoryKiB,
      ARGON2_DEFAULTS.iterations,
      ARGON2_DEFAULTS.parallelism,
    ),
  )
  const wrapped = await encryptFresh(kek, vk, wrapAad(workspaceId, wrapId, "passphrase"))
  return `${salt}|${KDF_PARAMS_JSON}|${wrapped}`
}

// "<recovery key text>|<wrapped key>" for a NEW recovery wrap. The recovery
// key text is the one value that must reach the user (shown once).
export async function vaultWrapRecovery(handle, workspaceId, wrapId) {
  const vk = vkOf(handle)
  const text = await generateRecoveryKey()
  const kek = b64uToBytes(await deriveRecoveryKek(text))
  const wrapped = await encryptFresh(kek, vk, wrapAad(workspaceId, wrapId, "recovery"))
  return `${text}|${wrapped}`
}

// "<credential id>|<wrapped key>" for a NEW passkey wrap.
export async function vaultWrapPasskey(handle, workspaceId, wrapId, rpId, rpName, userName) {
  const vk = vkOf(handle)
  const userId = await randomBytesB64u(16)
  const made = await createPasskey(rpId, rpName, userId, userName || "user", userName || "user")
  const [credId, kekB64u] = made.split(".")
  const wrapped = await encryptFresh(b64uToBytes(kekB64u), vk, wrapAad(workspaceId, wrapId, "passkey"))
  return `${credId}|${wrapped}`
}

function parseKdfParams(json) {
  try {
    const p = JSON.parse(json)
    return [p.memoryKiB, p.iterations, p.parallelism].map((n) => (Number.isInteger(n) ? n : NaN))
  } catch {
    throw new CryptoError("bad_params")
  }
}

async function openFromWrap(kekB64u, wrapped, workspaceId, wrapId, kind) {
  const vk = b64uToBytes(await unwrapVaultKey(kekB64u, wrapped, workspaceId, wrapId, kind))
  return openSession(vk)
}

// Unlock with a passphrase against a wrap's STORED salt + params + envelope.
export async function vaultUnlockPassphrase(passphrase, workspaceId, wrapId, saltB64u, kdfJson, wrapped) {
  const [m, t, p] = parseKdfParams(kdfJson)
  const kek = await derivePassphraseKek(passphrase, saltB64u, m, t, p)
  return openFromWrap(kek, wrapped, workspaceId, wrapId, "passphrase")
}

export async function vaultUnlockRecovery(text, workspaceId, wrapId, wrapped) {
  return openFromWrap(await deriveRecoveryKek(text), wrapped, workspaceId, wrapId, "recovery")
}

export async function vaultUnlockPasskey(credentialId, rpId, workspaceId, wrapId, wrapped) {
  return openFromWrap(await derivePasskeyKek(credentialId, rpId), wrapped, workspaceId, wrapId, "passkey")
}

// ---- remember this device ----------------------------------------------------
// The stored object is the session's NON-EXTRACTABLE CryptoKey (encrypt/decrypt
// only): scripts on this origin can use it but never read its bytes.

export async function deviceRemember(handle, workspaceId) {
  const { docKey } = sessionOf(handle)
  await store.put("device_keys", workspaceId, docKey)
  return "remembered"
}

export async function deviceHas(workspaceId) {
  return String((await store.get("device_keys", workspaceId)) != null)
}

// New session holding only the document key (cannot manage methods).
export async function deviceUnlock(workspaceId) {
  const key = await store.get("device_keys", workspaceId)
  if (!key || typeof key !== "object" || key.extractable !== false) throw new CryptoError("decrypt_failed")
  const handle = newHandle()
  sessions.set(handle, { vk: null, docKey: key })
  return handle
}

export async function deviceForget(workspaceId) {
  await store.del("device_keys", workspaceId)
  return "forgotten"
}

// ---- rollback detection (last seen rev + SHA-256 of the blob) ------------------

// "first" (nothing seen), "ok", or "rollback" (lower rev, or same rev with a
// different blob hash).
export async function seenCheck(workspaceId, revision, blob) {
  const rev = Number(revision)
  const rec = await store.get("seen", workspaceId)
  if (!rec) return "first"
  const hash = await sha256B64u(blob)
  if (rev < rec.rev) return "rollback"
  if (rev === rec.rev && hash !== rec.hash) return "rollback"
  return "ok"
}

// MONOTONIC: a stale write (a slow tab, a replayed older reply) never lowers
// the record, and a same-rev write with a different blob never replaces it.
// Only `seenAcknowledge` (an explicit user decision) can reset it.
export async function seenRecord(workspaceId, revision, blob) {
  const rev = Number(revision)
  if (!Number.isSafeInteger(rev) || rev < 0) throw new CryptoError("bad_input")
  const rec = await store.get("seen", workspaceId)
  if (rec && (rev < rec.rev || (rev === rec.rev && (await sha256B64u(blob)) !== rec.hash))) {
    return "kept"
  }
  await store.put("seen", workspaceId, { rev, hash: await sha256B64u(blob) })
  return "recorded"
}

// The user explicitly accepted a rollback (or a new vault replaced the old):
// the only way to lower the record. The caller logs it in state.
export async function seenAcknowledge(workspaceId, revision, blob) {
  const rev = Number(revision)
  if (!Number.isSafeInteger(rev) || rev < 0) throw new CryptoError("bad_input")
  await store.put("seen", workspaceId, { rev, hash: await sha256B64u(blob) })
  return "acknowledged"
}

// Start over / sign-out of a workspace: drops every local record for it.
export async function localWipe(workspaceId) {
  await store.del("device_keys", workspaceId)
  await store.del("seen", workspaceId)
  return "wiped"
}

// ---- Hologram surface -------------------------------------------------------
//
// ONLY the handle API (and feature detection / self test) is exposed to
// Hologram. The string-key functions above are named exports for the Node
// known-answer tests and for JS-side migration code; Elixir cannot reach them.

const PUBLIC = {
  prfSupported: async () => String(await prfSupported()),
  selfTest,
  vaultNew,
  vaultLock,
  vaultLockAll,
  vaultActive,
  vaultCanManage,
  vaultEncrypt,
  vaultDecrypt,
  vaultWrapPassphrase,
  vaultWrapRecovery,
  vaultWrapPasskey,
  vaultUnlockPassphrase,
  vaultUnlockRecovery,
  vaultUnlockPasskey,
  deviceRemember,
  deviceHas,
  deviceUnlock,
  deviceForget,
  seenCheck,
  seenRecord,
  seenAcknowledge,
  localWipe,
}

function wrap(fn) {
  return async (...args) => {
    try {
      return "ok:" + (await fn(...args))
    } catch (e) {
      // Only the code ever leaves; messages/stacks could echo secrets.
      return "err:" + (e instanceof CryptoError ? e.code : "internal")
    }
  }
}

const holo = Object.fromEntries(Object.entries(PUBLIC).map(([name, fn]) => [name, wrap(fn)]))

export default holo
