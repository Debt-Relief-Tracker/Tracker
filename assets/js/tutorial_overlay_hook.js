// The onboarding tutorial (DashboardLive) is a spotlight overlay: it dims
// the page and cuts a hole around whichever real element the current step
// points at, plus a tooltip card with the step's copy and Next/Back/Skip.
// The server only knows step data (target selector/title/body) -- it has no
// way to know an element's on-screen position, so positioning is entirely a
// client-side job. Like PlanChart, this hook owns its DOM
// (phx-update="ignore") and drives itself off pushed events rather than
// server-rendered HTML.
const TutorialOverlay = {
  mounted() {
    this.buildDom()
    this.currentTarget = null

    this.reposition = () => this.positionFor(this.currentTarget)
    window.addEventListener("resize", this.reposition)
    // `true` (capture phase) so scrolling inside the debt list or the main
    // panel -- not just the window -- also repositions the spotlight.
    window.addEventListener("scroll", this.reposition, true)

    this.handleEvent("tutorial-step", (step) => this.render(step))
  },

  buildDom() {
    this.backdrop = document.createElement("div")
    this.backdrop.className = "tutorial-overlay-backdrop"
    Object.assign(this.backdrop.style, {
      position: "fixed",
      inset: "0",
      zIndex: "9998",
      background: "rgba(0, 0, 0, 0.6)",
      transition: "clip-path 0.2s ease",
    })

    this.card = document.createElement("div")
    this.card.className = "tutorial-overlay-card bg-base-100 text-base-content rounded-lg shadow-xl p-4 w-80"
    Object.assign(this.card.style, {position: "fixed", zIndex: "9999"})

    this.progress = document.createElement("p")
    this.progress.className = "text-xs opacity-60 mb-1"

    this.title = document.createElement("h3")
    this.title.className = "font-semibold mb-2"

    this.body = document.createElement("p")
    this.body.className = "text-sm mb-4"

    const actions = document.createElement("div")
    actions.className = "flex items-center justify-between gap-2"

    this.skipButton = this.makeButton("Skip", "btn btn-ghost btn-sm", () => this.pushEvent("tutorial_skip", {}))
    this.backButton = this.makeButton("Back", "btn btn-soft btn-sm", () => this.pushEvent("tutorial_prev", {}))
    this.nextButton = this.makeButton("Next", "btn btn-primary btn-sm", () => this.pushEvent("tutorial_next", {}))

    const rightActions = document.createElement("div")
    rightActions.className = "flex items-center gap-2"
    rightActions.append(this.backButton, this.nextButton)
    actions.append(this.skipButton, rightActions)

    this.card.append(this.progress, this.title, this.body, actions)
    this.el.append(this.backdrop, this.card)
  },

  makeButton(label, className, onClick) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = className
    button.textContent = label
    button.addEventListener("click", onClick)
    return button
  },

  render(step) {
    this.currentTarget = step.target
    this.progress.textContent = `Step ${step.step} of ${step.total}`
    this.title.textContent = step.title
    this.body.textContent = step.body
    this.backButton.style.visibility = step.step === 1 ? "hidden" : "visible"
    this.nextButton.textContent = step.is_last ? "Finish" : "Next"

    const targetEl = step.target && document.querySelector(step.target)
    if (targetEl) targetEl.scrollIntoView({block: "center", inline: "nearest"})

    // Wait a frame for the scroll (and any server-driven DOM change, e.g.
    // the strategy switcher becoming visible) to settle before measuring.
    requestAnimationFrame(() => this.positionFor(step.target))
  },

  positionFor(target) {
    const targetEl = target && document.querySelector(target)

    if (!targetEl) {
      this.backdrop.style.clipPath = ""
      this.centerCard()
      return
    }

    const rect = targetEl.getBoundingClientRect()
    const pad = 8
    const hole = {
      left: rect.left - pad,
      top: rect.top - pad,
      right: rect.right + pad,
      bottom: rect.bottom + pad,
    }
    const {innerWidth: w, innerHeight: h} = window

    // A full-viewport rectangle plus the hole's rectangle wound the
    // opposite way, combined with the `evenodd` fill rule, punches a
    // transparent (and unclickable) hole out of the backdrop.
    this.backdrop.style.clipPath = [
      "polygon(evenodd,",
      `0px 0px, ${w}px 0px, ${w}px ${h}px, 0px ${h}px, 0px 0px,`,
      `${hole.left}px ${hole.top}px, ${hole.left}px ${hole.bottom}px,`,
      `${hole.right}px ${hole.bottom}px, ${hole.right}px ${hole.top}px, ${hole.left}px ${hole.top}px)`,
    ].join(" ")

    this.positionCardNear(rect)
  },

  positionCardNear(rect) {
    const cardWidth = 320
    const margin = 16
    const spaceBelow = window.innerHeight - rect.bottom

    const top =
      spaceBelow > 160 ? rect.bottom + margin : Math.max(margin, rect.top - margin - 160)
    const left = Math.min(
      Math.max(margin, rect.left),
      window.innerWidth - cardWidth - margin,
    )

    Object.assign(this.card.style, {top: `${top}px`, left: `${left}px`, right: "auto", transform: "none"})
  },

  centerCard() {
    Object.assign(this.card.style, {
      top: "50%",
      left: "50%",
      transform: "translate(-50%, -50%)",
    })
  },

  destroyed() {
    window.removeEventListener("resize", this.reposition)
    window.removeEventListener("scroll", this.reposition, true)
  },
}

export default TutorialOverlay
