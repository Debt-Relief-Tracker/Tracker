import Chart from "chart.js/auto"

// Whole-dollar formatting for axis ticks (e.g. "$1,234"); cents show in
// tooltips via tooltipCurrency instead, where the extra precision is useful.
const tickCurrency = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
})
const tooltipCurrency = new Intl.NumberFormat("en-US", {style: "currency", currency: "USD"})

// The server (DebtReliefTrackerWeb.Charts) sends chart data as plain numbers
// -- Chart.js can only plot numbers, and a config pushed over a LiveView
// event can't carry JS functions anyway. So comma/currency formatting for
// axis ticks and tooltips is applied here, client-side, based on the fixed
// set of chart shapes docs/architecture/0004-charting-library.md defines.
function applyCurrencyFormatting(config) {
  const scales = config.options?.scales || {}

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

    this.handleEvent("plan-chart-data", (config) => this.renderChart(config))
  },

  renderChart(config) {
    if (this.chart) {
      this.chart.destroy()
    }

    this.chart = new Chart(this.el, applyCurrencyFormatting(config))
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  },
}

export default PlanChart
