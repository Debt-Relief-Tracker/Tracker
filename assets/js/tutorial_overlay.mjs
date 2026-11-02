// Geometry + highlight only for the Hologram tutorial overlay. No step
// logic: Elixir (Holo.Components.TutorialOverlay) owns the steps and renders
// the card/backdrop; this module measures the target element and returns the
// inline styles for them. Visuals match the old tutorial_overlay_hook.js.
const BACKDROP_BASE =
  "position:fixed;inset:0;z-index:9998;background:rgba(0,0,0,0.6);transition:clip-path 0.2s ease;"
const CARD_BASE = "position:fixed;z-index:9999;"
const CARD_WIDTH = 320
const MARGIN = 16
const PAD = 8

let listening = false
let lastScrolled = null
let lastJson = ""

// Measures `target`; scrolls it into view only the first time a given target
// is shown (so repeated re-measures from scroll/mutation don't fight the user).
function layout(target) {
  if (!target) lastScrolled = null
  const result = measure(target, target !== lastScrolled)
  if (target) lastScrolled = target
  lastJson = JSON.stringify(result)
  return result
}

function measure(target, scroll) {
  const el = target ? document.querySelector(target) : null

  if (!el) {
    return {
      backdrop_style: BACKDROP_BASE,
      card_style: CARD_BASE + "top:50%;left:50%;transform:translate(-50%,-50%);",
    }
  }

  if (scroll) el.scrollIntoView({block: "center", inline: "nearest"})

  const rect = el.getBoundingClientRect()
  const w = window.innerWidth
  const h = window.innerHeight
  const l = rect.left - PAD
  const t = rect.top - PAD
  const r = rect.right + PAD
  const b = rect.bottom + PAD

  // Full-viewport rectangle plus the hole wound the opposite way, with the
  // evenodd fill rule, punches a transparent (and unclickable) hole.
  const clip =
    `polygon(evenodd, 0px 0px, ${w}px 0px, ${w}px ${h}px, 0px ${h}px, 0px 0px, ` +
    `${l}px ${t}px, ${l}px ${b}px, ${r}px ${b}px, ${r}px ${t}px, ${l}px ${t}px)`

  const spaceBelow = h - rect.bottom
  const top = spaceBelow > 160 ? rect.bottom + MARGIN : Math.max(MARGIN, rect.top - MARGIN - 160)
  const left = Math.min(Math.max(MARGIN, rect.left), w - CARD_WIDTH - MARGIN)

  return {
    backdrop_style: BACKDROP_BASE + `clip-path:${clip};`,
    card_style: CARD_BASE + `top:${top}px;left:${left}px;transform:none;`,
  }
}

// Ask the component to re-measure on resize / scroll (capture phase so inner
// scroll containers count) and when the DOM changes: a new step (the card's
// data-target) or e.g. a chart-type switch making the target appear. The
// target is read from the card, so Elixir never has to schedule a measure.
// Only pokes when the geometry actually changed, so the overlay's own
// re-render can't loop. Runs once, when this module loads.
function currentTarget() {
  const card = document.getElementById("tutorial-card")
  return card ? card.getAttribute("data-target") : null
}

function listen() {
  if (listening || typeof document === "undefined") return
  listening = true

  let queued = false
  const poke = () => {
    if (queued) return
    queued = true
    requestAnimationFrame(() => {
      queued = false
      const target = currentTarget()
      if (!target) return
      if (JSON.stringify(measure(target, false)) !== lastJson) {
        window.Hologram.dispatchAction("reposition", "tutorial_overlay", {})
      }
    })
  }

  window.addEventListener("resize", poke)
  window.addEventListener("scroll", poke, true)
  new MutationObserver((mutations) => {
    const relevant = mutations.some((m) => {
      if (m.attributeName === "data-target") return true
      const node = m.target.nodeType === 1 ? m.target : m.target.parentElement
      return !(node && node.closest("#tutorial-overlay"))
    })
    if (relevant) poke()
  }).observe(document.body, {childList: true, subtree: true, attributes: true})
}

listen()

export default {layout}
