// Browser environment facade for the E2EE vault session (ADR 0007, "Session"):
// clock, UUIDs, idle timer, cross-tab lock via BroadcastChannel, tab
// visibility, and the unsaved-changes warning. No app logic and NO secrets:
// the only things that ever cross a tab boundary are the words "locked" and
// "unlocked" on a per-workspace channel. It talks to the Hologram page by
// dispatching the `vault_session_event` action (JS -> Elixir); Elixir calls the
// plain functions below through DebtReliefTracker.VaultEnv.
//
// Nothing here uses eval, inline scripts, storage, cookies or URLs.

const ACTIVITY_EVENTS = ["pointerdown", "pointermove", "keydown", "touchstart", "wheel"]

let workspaceId = null
let channel = null
let tabId = null
let dirty = false
let idleMs = 0
let lastActivity = 0
let idleTimer = null
let initialised = false

// Pure: milliseconds until the idle timeout, <= 0 when it has expired.
export function idleRemaining(now, last, ms) {
  return last + ms - now
}

function emit(kind) {
  const h = globalThis.Hologram
  if (h && typeof h.dispatchAction === "function") h.dispatchAction("vault_session_event", "page", { kind })
}

function onActivity() {
  lastActivity = Date.now()
}

function scheduleIdle() {
  clearTimeout(idleTimer)
  idleTimer = null
  if (!(idleMs > 0)) return
  const left = idleRemaining(Date.now(), lastActivity, idleMs)
  idleTimer = setTimeout(
    () => {
      idleTimer = null
      if (idleRemaining(Date.now(), lastActivity, idleMs) <= 0) {
        idleMs = 0
        emit("idle")
      } else {
        scheduleIdle()
      }
    },
    Math.max(left, 10),
  )
}

// Idempotent per page load. Opens the cross-tab channel for the workspace and
// installs the visibility / beforeunload / activity listeners once.
export function envInit(ws) {
  workspaceId = ws
  if (!tabId) tabId = globalThis.crypto.randomUUID()
  if (initialised) return "ok"
  initialised = true
  if (typeof BroadcastChannel === "function") {
    channel = new BroadcastChannel("drt-vault:" + ws)
    channel.onmessage = (e) => {
      const m = e && e.data
      if (!m || m.from === tabId) return
      if (m.type === "locked") emit("remote_locked")
      else if (m.type === "unlocked") emit("remote_unlocked")
    }
  }
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") emit("visible")
  })
  window.addEventListener("beforeunload", (e) => {
    if (dirty) {
      e.preventDefault()
      e.returnValue = ""
    }
  })
  for (const name of ACTIVITY_EVENTS) document.addEventListener(name, onActivity, { passive: true, capture: true })
  return "ok"
}

// Debounce timer for the save loop: after `ms`, dispatch the page action
// `vault_flush %{token}`. It is a plain JS timer (not a delayed `put_action`)
// so that a Hologram handler's ONE follow-up action stays free for the
// component reply of an edit (ADR 0007, "Data path"). The token travels as a
// string; `VaultFlow.flush/2` compares it with the save loop's sequence.
export function flushLater(token, ms) {
  const t = String(token)
  setTimeout(
    () => {
      const h = globalThis.Hologram
      if (h && typeof h.dispatchAction === "function") h.dispatchAction("vault_flush", "page", { token: t })
    },
    Math.max(Number(ms) || 0, 0),
  )
  return "ok"
}

// Start the idle timer (ms; 0 disables).
export function idleStart(ms) {
  idleMs = Number(ms) || 0
  lastActivity = Date.now()
  scheduleIdle()
  return "ok"
}

export function idleStop() {
  idleMs = 0
  clearTimeout(idleTimer)
  idleTimer = null
  return "ok"
}

export function setDirty(flag) {
  dirty = flag === true || flag === "true"
  return "ok"
}

// type: "locked" | "unlocked". Reaches the OTHER tabs of this browser only.
export function broadcast(type) {
  if (channel && (type === "locked" || type === "unlocked")) channel.postMessage({ type, from: tabId })
  return "ok"
}

export function nowIso() {
  return new Date().toISOString()
}

export function todayIso() {
  const d = new Date()
  const p = (n) => String(n).padStart(2, "0")
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

export function randomUuid() {
  return globalThis.crypto.randomUUID()
}

// Copies text to the clipboard (the recovery key). Fire and forget.
export function copyText(text) {
  try {
    const p = globalThis.navigator.clipboard.writeText(String(text))
    if (p && p.catch) p.catch(() => {})
  } catch {
    // clipboard unavailable: the user can still select and copy by hand
  }
  return "ok"
}

export function monotonicMs() {
  return Math.floor(Date.now())
}

const env = { flushLater, envInit, idleStart, idleStop, setDirty, broadcast, nowIso, todayIso, randomUuid, monotonicMs, copyText }
export default env
