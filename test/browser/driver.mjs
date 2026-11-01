// Line-delimited JSON driver between ExUnit (DebtReliefTracker.BrowserCase) and
// headless Chromium. One request per stdin line: {id, cmd, args}; one reply per
// stdout line: {id, ok, value | error}. All app logic stays in Elixir.
import { createRequire } from "node:module";
import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import readline from "node:readline";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright-core");

const TIMEOUT = Number(process.env.BROWSER_TEST_TIMEOUT_MS || 10000);

// Prefer an explicit override, then the cached headless shell, then full chromium.
function findChromium() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH;
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH || join(homedir(), ".cache", "ms-playwright");
  const candidates = [
    ["chromium_headless_shell-", "chrome-linux/headless_shell"],
    ["chromium-", "chrome-linux/chrome"],
  ];
  if (existsSync(root)) {
    for (const [prefix, bin] of candidates) {
      for (const dir of readdirSync(root).filter((d) => d.startsWith(prefix)).sort().reverse()) {
        const p = join(root, dir, bin);
        if (existsSync(p)) return p;
      }
    }
  }
  throw new Error("no cached Chromium found; set CHROMIUM_PATH");
}

const browser = await chromium.launch({
  executablePath: findChromium(),
  headless: true,
  args: ["--no-sandbox"],
});
const context = await browser.newContext();
const page = await context.newPage();
page.setDefaultTimeout(TIMEOUT);
// Console errors / uncaught page errors, readable with the `errors` command.
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e && e.message ? e.message : e)));
// Console listeners are costly (Hologram logs every function call it runs),
// so they are attached only on request.
if (process.env.BROWSER_LOG_ALL) {
  page.on("console", (m) => pageErrors.push(m.type() + ": " + m.text().slice(0, 300)));
}
page.on("response", (r) => {
  if (r.status() >= 400) pageErrors.push(`HTTP ${r.status()} ${r.url()}`);
});

const handlers = {
  async visit({ url }) {
    await page.goto(url, { waitUntil: "load" });
  },
  async wait_mounted({ page: name }) {
    await page.waitForFunction(
      (n) => {
        const h = globalThis.Hologram;
        return h && h.mountedPage === n && h["wsConnected?"] && h["sseConnected?"];
      },
      name,
    );
  },
  async click({ selector }) {
    await page.click(selector);
  },
  async fill({ selector, value }) {
    await page.fill(selector, value);
  },
  async text({ selector }) {
    return await page.locator(selector).first().innerText();
  },
  async wait_for_selector({ selector, state }) {
    await page.waitForSelector(selector, { state: state || "visible" });
  },
  async wait_for_text({ selector, text }) {
    await page.waitForFunction(
      ([s, t]) => {
        const el = document.querySelector(s);
        return !!el && el.innerText.includes(t);
      },
      [selector, text],
    );
  },
  async count({ selector }) {
    return await page.locator(selector).count();
  },
  async select({ selector, value }) {
    await page.selectOption(selector, value);
  },
  async press({ key }) {
    await page.keyboard.press(key);
  },
  async errors() {
    return pageErrors;
  },
  async viewport({ width, height }) {
    await page.setViewportSize({ width, height });
  },
  async click_at({ selector, x, y }) {
    await page.click(selector, { position: { x, y } });
  },
  async add_cookie({ name, value, url }) {
    await context.addCookies([{ name, value, url }]);
  },
  async cookies() {
    return await context.cookies();
  },
  async eval({ expr }) {
    return await page.evaluate(expr);
  },
  async attr({ selector, name }) {
    return await page.locator(selector).first().getAttribute(name);
  },
  async wait_for_expr({ expr }) {
    await page.waitForFunction(expr);
  },
  async wait_for_url({ pattern }) {
    await page.waitForURL(new RegExp(pattern));
  },
  async select_option({ selector, value }) {
    await page.selectOption(selector, value);
  },
  async path() {
    return new URL(page.url()).pathname;
  },
};

const rl = readline.createInterface({ input: process.stdin });
const send = (o) => process.stdout.write(JSON.stringify(o) + "\n");
send({ id: 0, ok: true, value: "ready" });

rl.on("line", async (line) => {
  let req;
  try {
    req = JSON.parse(line);
    const fn = handlers[req.cmd];
    if (!fn) throw new Error(`unknown cmd ${req.cmd}`);
    send({ id: req.id, ok: true, value: (await fn(req.args || {})) ?? null });
  } catch (e) {
    send({ id: req?.id ?? -1, ok: false, error: String(e && e.message ? e.message : e) });
  }
});
rl.on("close", async () => {
  await browser.close();
  process.exit(0);
});
