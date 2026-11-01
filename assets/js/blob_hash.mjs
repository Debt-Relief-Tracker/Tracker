// SHA-256 (lowercase hex) of the UTF-8 bytes of a string, via WebCrypto.
// Used by the migration screen to bind "finalize" to the exact vault blob it
// verified. Resolves to "ok:<hex>" or "err:hash"; never throws.
async function sha256Hex(str) {
  try {
    const bytes = new TextEncoder().encode(String(str))
    const digest = await crypto.subtle.digest("SHA-256", bytes)
    const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("")
    return "ok:" + hex
  } catch (_e) {
    return "err:hash"
  }
}

export default { sha256Hex }
