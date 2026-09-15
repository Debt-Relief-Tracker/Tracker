import Chart from "chart.js/auto"

// Whole-dollar formatting for axis ticks (e.g. "$1,234"); cents show in
// tooltips via the tooltip formatter instead, where the extra precision is
// useful. The server (DashboardLive.push_chart_data/1) includes the
// workspace's currency as a top-level `currency` key on the pushed config,
// so these are built per-render rather than fixed to "USD".
function tickCurrencyFormatter(currency) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency,
    maximumFractionDigits: 0,
  })
}

function tooltipCurrencyFormatter(currency) {
  return new Intl.NumberFormat("en-US", {style: "currency", currency})
}

// Mirrors DebtReliefTrackerWeb.Charts's @palette (light-mode colors, as sent
// by the server) with a brighter dark-mode counterpart per hue (the same
// Tailwind 600 -> 400 shift used for the app's own dark theme), plus the two
// one-off literals used outside the palette (the simulation chart's dashed
// "Total" line, and the freed-cashflow area fill). Theme changes are a pure
// client-side concern (see root.html.heex's inline script) -- recoloring
// here avoids a server round-trip just to swap colors already in the
// browser.
const LIGHT_PALETTE = [
  "#2563eb",
  "#f97316",
  "#16a34a",
  "#dc2626",
  "#9333ea",
  "#0891b2",
  "#ca8a04",
  "#db2777",
]
const DARK_PALETTE = [
  "#60a5fa",
  "#fb923c",
  "#4ade80",
  "#f87171",
  "#c084fc",
  "#22d3ee",
  "#facc15",
  "#f472b6",
]
const LIGHT_TOTAL_LINE = "#111827"
const DARK_TOTAL_LINE = "#e5e7eb"
const LIGHT_FILL = "rgba(37, 99, 235, 0.2)"
const DARK_FILL = "rgba(96, 165, 250, 0.25)"

function currentTheme() {
  const attr = document.documentElement.getAttribute("data-theme")
  if (attr === "light" || attr === "dark") return attr
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
}

// Builds a light-hex -> theme-appropriate-hex lookup, then walks a cloned
// copy of the server's config swapping any dataset color that matches a
// known literal -- this works regardless of which literal a given chart
// type happens to assign to which dataset/index (e.g. the comparison chart
// assigns palette colors out of order), since it matches by value, not
// position.
function colorMap(theme) {
  const map = new Map()
  LIGHT_PALETTE.forEach((hex, i) => map.set(hex, theme === "dark" ? DARK_PALETTE[i] : hex))
  map.set(LIGHT_TOTAL_LINE, theme === "dark" ? DARK_TOTAL_LINE : LIGHT_TOTAL_LINE)
  map.set(LIGHT_FILL, theme === "dark" ? DARK_FILL : LIGHT_FILL)
  return map
}

function swapColor(value, map) {
  if (Array.isArray(value)) return value.map((v) => swapColor(v, map))
  return typeof value === "string" && map.has(value) ? map.get(value) : value
}

function recolor(config, theme) {
  const map = colorMap(theme)
  const recolored = JSON.parse(JSON.stringify(config))

  for (const dataset of recolored.data?.datasets || []) {
    if ("backgroundColor" in dataset) dataset.backgroundColor = swapColor(dataset.backgroundColor, map)
    if ("borderColor" in dataset) dataset.borderColor = swapColor(dataset.borderColor, map)
  }

  return recolored
}

// The server (DebtReliefTrackerWeb.Charts) sends chart data as plain numbers
// -- Chart.js can only plot numbers, and a config pushed over a LiveView
// event can't carry JS functions anyway. So comma/currency formatting for
// axis ticks and tooltips is applied here, client-side, based on the fixed
// set of chart shapes docs/architecture/0004-charting-library.md defines.
function applyCurrencyFormatting(config) {
  const scales = config.options?.scales || {}
  const currency = config.currency || "USD"
  const tickCurrency = tickCurrencyFormatter(currency)
  const tooltipCurrency = tooltipCurrencyFormatter(currency)

  if (config.type === "bar") {
    // Comparison chart: "interest" scale/dataset is a dollar amount, "months" isn't.
    if (scales.interest) {
      scales.interest.ticks = {...scales.interest.ticks, callback: tickCurrency.format}
    }

    setTooltipLabel(config, (ctx) => {
      const value = ctx.parsed.y
      return ctx.dataset.yAxisID === "interest"
        ? `${ctx.dataset.label}: ${tooltipCurrency.format(value)}`
        : `${ctx.dataset.label}: ${value} ${value === 1 ? "month" : "months"}`
    })
  } else if (config.type === "line") {
    // Simulation and freed-cashflow charts: the one "y" scale is always a dollar amount.
    if (scales.y) {
      scales.y.ticks = {...scales.y.ticks, callback: tickCurrency.format}
    }

    setTooltipLabel(config, (ctx) => `${ctx.dataset.label}: ${tooltipCurrency.format(ctx.parsed.y)}`)
  } else if (config.type === "doughnut") {
    setTooltipLabel(config, (ctx) => `${ctx.label}: ${tooltipCurrency.format(ctx.parsed)}`)
  }

  return config
}

function setTooltipLabel(config, labelFn) {
  const options = (config.options ||= {})
  const plugins = (options.plugins ||= {})
  const tooltip = (plugins.tooltip ||= {})
  const callbacks = (tooltip.callbacks ||= {})
  callbacks.label = labelFn
}

// Renders whichever payoff-plan chart is selected (docs/plan.md Phase 5).
// The server computes the full Chart.js config (type/data/options) for the
// active chart type and strategy, and pushes it as an event -- this hook
// just (re)instantiates Chart.js with whatever config arrives. Destroying
// and recreating the chart on every update is simpler and more robust than
// trying to patch an existing instance across chart-type changes (bar ->
// line -> doughnut have incompatible configs).
const PlanChart = {
  mounted() {
    this.chart = null
    this.lastConfig = null

    this.handleEvent("plan-chart-data", (config) => {
      this.lastConfig = config
      this.renderChart(config)
    })

    // Recolors and re-renders in place when the theme toggle (or a
    // cross-tab theme change -- see root.html.heex) flips data-theme,
    // without waiting for the next server push.
    this.themeObserver = new MutationObserver(() => {
      if (this.lastConfig) this.renderChart(this.lastConfig)
    })
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })
  },

  renderChart(config) {
    if (this.chart) {
      this.chart.destroy()
    }

    const themed = recolor(config, currentTheme())
    this.chart = new Chart(this.el, applyCurrencyFormatting(themed))
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
    if (this.themeObserver) {
      this.themeObserver.disconnect()
    }
  },
}

export default PlanChart
