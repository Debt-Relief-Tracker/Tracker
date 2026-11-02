// Drives headless Chromium over the DevTools protocol (Node's built-in
// WebSocket, no npm deps) through the Hologram plan panel and prints one
// JSON report. Run by test/debt_relief_tracker_web/holo/plan_chart_browser_test.exs
// against a test-only listener on the test database -- never the dev server.
//
//   node plan_chart_check.mjs <chromium> <base_url> <screenshot_dir>
import {spawn} from "node:child_process"
import {mkdtempSync, writeFileSync, rmSync} from "node:fs"
import {tmpdir} from "node:os"
import {join} from "node:path"

const [chromium, baseUrl, shotDir] = process.argv.slice(2)
const port = 9400 + Math.floor(Math.random() * 500)
const profile = mkdtempSync(join(tmpdir(), "plan-chart-"))
const browser = spawn(chromium, [
  "--headless=new",
  "--no-sandbox",
  "--disable-gpu",
  "--window-size=1280,1000",
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${profile}`,
  "about:blank",
])

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const report = {steps: {}, errors: [], console: [], timings: []}

async function pageSocketUrl() {
  for (let i = 0; i < 100; i++) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
      const page = targets.find((t) => t.type === "page")
      if (page) return page.webSocketDebuggerUrl
    } catch (_) {}
    await sleep(100)
  }
  throw new Error("chromium did not start")
}

let ws
let nextId = 1
const pending = new Map()

function send(method, params = {}) {
  const id = nextId++
  ws.send(JSON.stringify({id, method, params}))
  return new Promise((resolve, reject) => pending.set(id, {resolve, reject}))
}

// Rejects instead of hanging when the page's main thread is busy.
async function evaluate(expression, timeout = 5000) {
  const res = await Promise.race([
    send("Runtime.evaluate", {expression, awaitPromise: true, returnByValue: true}),
    sleep(timeout).then(() => {
      throw new Error(`page unresponsive for ${timeout}ms evaluating ${expression.slice(0, 60)}`)
    }),
  ])
  if (res.exceptionDetails) throw new Error(JSON.stringify(res.exceptionDetails))
  return res.result.value
}

async function waitFor(expression, timeout = 15000) {
  const start = Date.now()
  while (Date.now() - start < timeout) {
    try {
      if (await evaluate(expression)) return true
    } catch (error) {
      report.console.push(String(error.message || error))
    }
    await sleep(100)
  }
  return false
}

// How many painted pixels the chart canvas has (0 = blank / no canvas).
const PAINTED = `(() => {
  const c = document.querySelector('#plan-chart canvas');
  if (!c || !c.width || !c.height) return 0;
  const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
  let n = 0; for (let i = 3; i < d.length; i += 4) if (d[i] > 0) n++;
  return n;
})()`
const SIGNATURE = `(() => { const c = document.querySelector('#plan-chart canvas'); return c ? c.toDataURL().length + ':' + c.toDataURL().slice(-64) : null })()`
const CANVAS_COUNT = `document.querySelectorAll('#plan-chart canvas').length`

async function click(selector) {
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`)
}

async function typeBudget(value) {
  await evaluate(`(() => {
    const el = document.querySelector('#budget-input');
    el.focus();
    el.value = ${JSON.stringify(value)};
    el.dispatchEvent(new Event('input', {bubbles: true}));
  })()`)
}

async function shot(name) {
  const {data} = await send("Page.captureScreenshot", {format: "png"})
  writeFileSync(join(shotDir, `${name}.png`), Buffer.from(data, "base64"))
}

// Moves the page's own error/timing logs into the report (before a reload
// wipes them, and at the end).
async function collectPage() {
  try {
    const page = await evaluate(`({errors: window.__errors || [], timings: window.__timings || []})`)
    report.errors.push(...page.errors)
    report.timings.push(...page.timings)
  } catch (error) {
    report.errors.push(`could not read page logs: ${error.message}`)
  }
}

async function changedFrom(signature) {
  return waitFor(`${SIGNATURE} !== null && ${SIGNATURE} !== ${JSON.stringify(signature)}`)
}

async function run() {
  ws = new WebSocket(await pageSocketUrl())
  await new Promise((resolve) => ws.addEventListener("open", resolve))

  ws.addEventListener("message", (event) => {
    const msg = JSON.parse(event.data)
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id).resolve(msg.result || {exceptionDetails: msg.error})
      pending.delete(msg.id)
    }
  })

  // Errors and Hologram's per-action timings are collected in the page, NOT
  // via Runtime.enable: Hologram 0.12.4 console.logs every function call
  // during an action, and streaming those over CDP stalls the page for
  // tens of seconds -- a test artifact, not what a user's browser does.
  await send("Page.enable")
  await send("Page.addScriptToEvaluateOnNewDocument", {
    source: `
      window.__errors = []; window.__timings = [];
      addEventListener("error", (e) => __errors.push(String((e.error && e.error.stack) || e.message)));
      addEventListener("unhandledrejection", (e) => __errors.push(String((e.reason && e.reason.stack) || e.reason)));
      const error = console.error.bind(console);
      console.error = (...a) => { __errors.push(a.map(String).join(" ")); error(...a) };
      const log = console.log.bind(console);
      console.log = (...a) => {
        if (typeof a[0] === "string" && a[0].startsWith("Hologram: action")) __timings.push(a.join(" "));
        log(...a);
      };`,
  })
  await send("Page.navigate", {url: `${baseUrl}/app`})

  const s = report.steps

  // 1. First load: the comparison chart is drawn after the page mounts.
  const loadStart = Date.now()
  s.initial_canvas = await waitFor(`${PAINTED} > 500`, 30000)
  report.first_chart_ms = Date.now() - loadStart
  s.initial_painted = await evaluate(PAINTED)
  await shot("1-comparison")
  let sig = await evaluate(SIGNATURE)

  // 2. Simulation chart: redrawn, strategy switcher appears.
  await click("#chart-type-simulation")
  s.simulation_redrawn = await changedFrom(sig)
  s.strategy_switcher = await evaluate(`!!document.querySelector('#strategy-switcher')`)
  s.single_canvas = (await evaluate(CANVAS_COUNT)) === 1
  await shot("2-simulation")
  sig = await evaluate(SIGNATURE)

  // 3. Strategy change goes through the page and back to the chart.
  await click("#strategy-avalanche")
  s.strategy_selected = await waitFor(`document.querySelector('#strategy-avalanche').classList.contains('btn-primary')`)
  sig = (await evaluate(SIGNATURE)) || sig

  // 4. A chart with nothing to plot: message shown, canvas removed.
  await click("#chart-type-interest_breakdown")
  s.message_shown = await waitFor(`(document.querySelector('#plan-chart-message')?.textContent || '').includes('Log a payment')`)
  s.canvas_removed = await waitFor(`${CANVAS_COUNT} === 0`)

  // 4b. Retirement roadmap with no profiles: its setup message.
  await click("#chart-type-retirement_roadmap")
  s.retirement_message = await waitFor(`(document.querySelector('#plan-chart-message')?.textContent || '').includes('retirement profile')`)

  // 5. Back to a chart: a fresh canvas in the same container.
  await click("#chart-type-monthly_payments")
  s.canvas_back = await waitFor(`${PAINTED} > 500`)
  await shot("3-monthly-payments")
  sig = await evaluate(SIGNATURE)

  // 6. Budget below the minimums: budget messages (never "add a debt").
  await typeBudget("10")
  s.budget_message = await waitFor(
    `(document.querySelector('#plan-chart-message')?.textContent || '').includes('budget') &&
     (document.querySelector('#this-month-message')?.textContent || '').includes('budget') &&
     !document.querySelector('#plan-panel').textContent.includes('Add a debt')`,
  )

  // 7. A real budget: the chart comes back, the save persists (reload).
  await typeBudget("1000")
  s.budget_chart_back = await waitFor(`${PAINTED} > 500`)
  await evaluate(`document.querySelector('#budget-input').blur()`)
  await sleep(2500)
  await collectPage()
  await send("Page.reload")
  await sleep(500)
  s.budget_persisted = await waitFor(`document.querySelector('#budget-input')?.value === '1000.00'`)
  s.reload_canvas = await waitFor(`${PAINTED} > 500`)
  sig = await evaluate(SIGNATURE)

  // 8. Theme flip redraws with the dark palette.
  await evaluate(`document.documentElement.setAttribute('data-theme', 'dark')`)
  s.dark_redrawn = await changedFrom(sig)
  await shot("4-dark")

  // 9. Mobile width: the select pickers drive the same actions.
  await send("Emulation.setDeviceMetricsOverride", {width: 390, height: 844, deviceScaleFactor: 1, mobile: true})
  await evaluate(`(() => { const el = document.querySelector('#chart-type-select'); el.value = 'freed_cashflow'; el.dispatchEvent(new Event('change', {bubbles: true})); })()`)
  s.mobile_select = await waitFor(`!!document.querySelector('#chart-type-freed_cashflow.btn-primary') && ${PAINTED} > 200`)
  await shot("5-mobile")
  await collectPage()
}

const timer = setTimeout(() => {
  report.errors.push("timed out")
  finish(1)
}, 170000)

function finish(code) {
  clearTimeout(timer)
  process.stdout.write(JSON.stringify(report) + "\n")
  try {
    ws?.close()
  } catch (_) {}
  browser.kill("SIGKILL")
  try {
    rmSync(profile, {recursive: true, force: true})
  } catch (_) {}
  process.exit(code)
}

run().then(
  () => finish(0),
  (error) => {
    report.errors.push(String(error && error.stack ? error.stack : error))
    finish(1)
  },
)
