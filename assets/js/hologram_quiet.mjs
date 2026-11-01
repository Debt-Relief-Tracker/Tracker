// Hologram 0.12.4 switches `isProfilingEnabled` on at the start of every
// client action, and while it is on, console.logs the duration of EVERY
// Elixir function call. A payoff re-plan makes hundreds of thousands of
// calls, so that logging alone turned a ~1s simulation into ~25s of frozen
// page. Pin the flag to false (writes are ignored); the per-action summary
// log line is unaffected.
function quiet() {
  const h = globalThis.Hologram
  if (!h) return
  try {
    Object.defineProperty(h, "isProfilingEnabled", {
      configurable: true,
      get: () => false,
      set: () => {},
    })
  } catch (_e) {
    // Not defineable on this Hologram version; harmless.
  }
}

quiet()

export default {quiet}
