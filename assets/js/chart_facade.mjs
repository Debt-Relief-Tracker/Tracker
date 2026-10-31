// Chart.js facade for Hologram (docs/architecture/0007-e2ee.md: JS is
// facades only). Config in, chart out: every config is built in Elixir
// (DebtReliefTracker.Engine.Charts); this file only draws it, applies the
// declarative formatting the config asks for, and redraws on theme changes.
// Called through DebtReliefTrackerWeb.Holo.ChartJS -- never directly.
//
// Bundled by Hologram's esbuild from assets/node_modules (npm install
// --prefix assets), like the LiveView bundle; no CDN.
import {
  ArcElement,
  BarController,
  BarElement,
  CategoryScale,
  Chart,
  DoughnutController,
  Filler,
  Legend,
  LinearScale,
  LineController,
  LineElement,
  PointElement,
  Tooltip,
} from "chart.js"

// Only what the app's chart types use (bar, line/area, doughnut), so the
// bundle doesn't carry every controller and scale chart.js/auto would.
Chart.register(
  ArcElement,
  BarController,
  BarElement,
  CategoryScale,
  DoughnutController,
  Filler,
  Legend,
  LinearScale,
  LineController,
  LineElement,
  PointElement,
  Tooltip,
)

// container id -> {chart, variants, observer, media}
const mounted = new Map()

function currentTheme() {
  const attr = document.documentElement.getAttribute("data-theme")
  if (attr === "light" || attr === "dark") return attr
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
}

function numberFormatter(locale, options) {
  const format = new Intl.NumberFormat(locale || "en-US", options)
  return (value) => format.format(value)
}

// Turns the config's declarative formatting into Chart.js callbacks:
//   scale.ticks.format       -> Intl.NumberFormat options for tick labels
//   dataset.valueFormat      -> Intl.NumberFormat options for the tooltip value
//   dataset.afterLabels[i]   -> a ready-made extra tooltip line per point
function withFormatting(config) {
  const prepared = structuredClone(config)
  const options = (prepared.options ||= {})
  const locale = options.locale

  for (const scale of Object.values(options.scales || {})) {
    if (scale.ticks?.format) {
      const format = numberFormatter(locale, scale.ticks.format)
      scale.ticks = {...scale.ticks, callback: (value) => format(value)}
      delete scale.ticks.format
    }
  }

  const datasets = prepared.data?.datasets || []
  const formats = datasets.map((d) => d.valueFormat && numberFormatter(locale, d.valueFormat))

  if (formats.some(Boolean) || datasets.some((d) => d.afterLabels)) {
    const plugins = (options.plugins ||= {})
    const tooltip = (plugins.tooltip ||= {})
    const callbacks = (tooltip.callbacks ||= {})

    callbacks.label = (ctx) => {
      const value = typeof ctx.parsed === "number" ? ctx.parsed : ctx.parsed.y
      const format = formats[ctx.datasetIndex]
      const name = ctx.dataset.label ?? ctx.label
      return `${name}: ${format ? format(value) : value}`
    }

    callbacks.afterLabel = (ctx) => ctx.dataset.afterLabels?.[ctx.dataIndex] ?? ""
  }

  return prepared
}

function draw(entry, canvas) {
  if (entry.chart) entry.chart.destroy()
  const config = entry.variants[currentTheme()] || entry.variants.light
  entry.chart = new Chart(canvas, withFormatting(config))
}

// Draws `variants` ({light: config, dark: config}) into the element with id
// `containerId`, replacing whatever chart was there. The canvas is created
// here, inside the container, so Hologram's re-renders leave it alone.
// Returns false when the container isn't in the DOM.
export function render(containerId, variants) {
  const container = document.getElementById(containerId)
  if (!container) return false

  let entry = mounted.get(containerId)

  if (entry && !container.contains(entry.chart?.canvas)) {
    destroy(containerId)
    entry = undefined
  }

  if (!entry) {
    const created = {chart: null, variants}
    created.redraw = () => created.chart && draw(created, created.chart.canvas)
    created.observer = new MutationObserver(created.redraw)
    created.observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })
    created.media = window.matchMedia("(prefers-color-scheme: dark)")
    created.media.addEventListener("change", created.redraw)
    mounted.set(containerId, created)
    entry = created
  }

  entry.variants = variants
  let canvas = entry.chart?.canvas
  if (!canvas) {
    canvas = document.createElement("canvas")
    container.appendChild(canvas)
  }
  draw(entry, canvas)
  return true
}

// Removes the chart (and its canvas) from `containerId`, if any.
export function destroy(containerId) {
  const entry = mounted.get(containerId)
  if (!entry) return false

  entry.observer.disconnect()
  entry.media.removeEventListener("change", entry.redraw)
  if (entry.chart) {
    const canvas = entry.chart.canvas
    entry.chart.destroy()
    canvas.remove()
  }
  mounted.delete(containerId)
  return true
}

export default {render, destroy}
