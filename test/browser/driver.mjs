// Line-delimited JSON driver between ExUnit (DebtReliefTracker.BrowserCase) and
// headless Chromium. One request per stdin line: {id, cmd, args}; one reply per
// stdout line: {id, ok, value | error}. All app logic stays in Elixir.
import { createRequire } from "node:module";
import { appendFileSync, existsSync, readdirSync } from "node:fs";
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
// Console errors / uncaught page errors, readable with the `errors` command.
const pageErrors = [];

// Every tab gets the same listeners. Tabs are addressed by name: each request
// may carry `args.tab` (default "main") and the handlers below act on `page`,
// which is pointed at that tab before the handler runs. `new_tab`/`close_tab`
// manage the extra tabs (same browser context, so they share storage and
// BroadcastChannel like real tabs of one browser).
function setupPage(p) {
  p.setDefaultTimeout(TIMEOUT);
  p.on("pageerror", (e) => pageErrors.push(String(e && e.message ? e.message : e)));
  // Console listeners are costly (Hologram logs every function call it runs),
  // so they are attached only on request.
  if (process.env.BROWSER_LOG_ALL) {
    p.on("console", (m) => pageErrors.push(m.type() + ": " + m.text().slice(0, 300)));
  }
  p.on("response", (r) => {
    if (r.status() >= 400) pageErrors.push(`HTTP ${r.status()} ${r.url()}`);
  });
}

// Content-Security-Policy violations (enforced or report-only). Recorded in
// pageErrors (readable with `errors`) and, when BROWSER_CSP_LOG names a file,
// appended there as JSON lines so the ExUnit side can fail the test even if
// the violation happened after the test's last driver call.
await context.exposeFunction("__reportCspViolation", (v) => {
  pageErrors.push("CSP violation: " + JSON.stringify(v));
  if (process.env.BROWSER_CSP_LOG) appendFileSync(process.env.BROWSER_CSP_LOG, JSON.stringify(v) + "\n");
});
await context.addInitScript(() => {
  document.addEventListener(
    "securitypolicyviolation",
    (e) =>
      window.__reportCspViolation({
        directive: e.effectiveDirective,
        blocked: e.blockedURI,
        document: e.documentURI,
        source: e.sourceFile,
        line: e.lineNumber,
        sample: e.sample,
        disposition: e.disposition,
      }),
    true,
  );
});

const tabs = new Map();
let page = await context.newPage();
setupPage(page);
tabs.set("main", page);

// BROWSER_TEST_DEBUG=1 mirrors page console/errors/navigations to stderr.
if (process.env.BROWSER_TEST_DEBUG) {
  const log = (...a) => process.stderr.write("[browser] " + a.join(" ") + "\n");
  page.on("console", (m) => { if (process.env.BROWSER_TEST_DEBUG === "all" || (m.type() !== "log" && m.type() !== "debug")) log("console." + m.type(), m.text()); });
  page.on("pageerror", (e) => log("pageerror", String(e.message), String(e.stack).slice(0, 1500), JSON.stringify(e)));
  page.on("requestfailed", (r) => log("request-failed", r.method(), r.url(), r.failure()?.errorText));
  page.on("response", (r) => log("response", r.status(), r.url(), r.headers()["content-type"] || ""));
  page.on("framenavigated", (f) => log("navigated", f.url()));
  page.on("request", (r) => { if (r.isNavigationRequest()) log("nav-request", r.method(), r.url()); });
  page.addInitScript(() => {
    document.addEventListener("submit", (e) => console.warn("submit event; defaultPrevented-at-bubble=" + e.defaultPrevented), false);
    document.addEventListener("submit", (e) => setTimeout(() => console.warn("submit after: prevented=" + e.defaultPrevented), 0), true);
  });
}

// page.waitForFunction evaluates its predicate with `eval` inside the page,
// which the app's strict CSP (no 'unsafe-eval') refuses. page.evaluate goes
// through the DevTools protocol and is unaffected, so poll with it instead.
async function waitFor(fn, arg, what) {
  const deadline = Date.now() + TIMEOUT;
  let last;
  for (;;) {
    try {
      if (await page.evaluate(fn, arg)) return;
    } catch (e) {
      last = e; // e.g. the execution context was destroyed by a navigation
    }
    if (Date.now() > deadline) {
      throw new Error(`timeout ${TIMEOUT}ms waiting for ${what}` + (last ? ` (${last.message})` : ""));
    }
    await new Promise((r) => setTimeout(r, 50));
  }
}

const handlers = {
  async visit({ url }) {
    await page.goto(url, { waitUntil: "load" });
  },
  async wait_mounted({ page: name }) {
    await waitFor(
      (n) => {
        const h = globalThis.Hologram;
        return h && h.mountedPage === n && h["wsConnected?"] && h["sseConnected?"];
      },
      name,
      `page ${name} mounted`,
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
    await waitFor(
      ([s, t]) => {
        const el = document.querySelector(s);
        return !!el && el.innerText.includes(t);
      },
      [selector, text],
      `${selector} to contain ${text}`,
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
  async screenshot({ path, fullPage }) {
    await page.screenshot({ path, fullPage: !!fullPage });
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
    await waitFor(expr, undefined, `expression ${expr}`);
  },
  async wait_for_url({ pattern }) {
    await page.waitForURL(new RegExp(pattern));
  },
  async select_option({ selector, value }) {
    await page.selectOption(selector, value);
  },
  async check({ selector }) {
    await page.check(selector);
  },
  async value({ selector }) {
    return await page.locator(selector).first().inputValue();
  },
  // Click at viewport coordinates (e.g. on a modal backdrop).
  async click_xy({ x, y }) {
    await page.mouse.click(x, y);
  },
  // Chromium virtual WebAuthn authenticator (CDP). `hasPrf` is passed through so
  // a Chromium build that lacks it fails loudly in the returned error.
  async webauthn_enable({ hasPrf }) {
    const cdp = await context.newCDPSession(page);
    await cdp.send("WebAuthn.enable", { enableUI: false });
    const r = await cdp.send("WebAuthn.addVirtualAuthenticator", {
      options: {
        protocol: "ctap2",
        ctap2Version: "ctap2_1",
        transport: "internal",
        hasResidentKey: true,
        hasUserVerification: true,
        isUserVerified: true,
        automaticPresenceSimulation: true,
        hasPrf: hasPrf !== false,
      },
    });
    return r.authenticatorId;
  },
  async new_tab({ name }) {
    const p = await context.newPage();
    setupPage(p);
    tabs.set(name, p);
  },
  async close_tab({ name }) {
    const p = tabs.get(name);
    if (p) await p.close();
    tabs.delete(name);
  },
  async reload() {
    await page.reload({ waitUntil: "load" });
  },
  // Dispatch a cancelable `beforeunload` and report whether a handler asked
  // for the "leave site?" prompt (defaultPrevented), without leaving.
  async beforeunload_prevented() {
    return await page.evaluate(() => {
      const e = new Event("beforeunload", { cancelable: true });
      window.dispatchEvent(e);
      return e.defaultPrevented;
    });
  },
  // Cookies, localStorage, sessionStorage and every IndexedDB database/store
  // of the page's origin (keys, and for CryptoKeys only their properties).
  async storage_dump() {
    return await page.evaluate(async () => {
      const out = { cookie: document.cookie, local: {}, session: {}, idb: {} };
      for (let i = 0; i < localStorage.length; i++) out.local[localStorage.key(i)] = localStorage.getItem(localStorage.key(i));
      for (let i = 0; i < sessionStorage.length; i++) out.session[sessionStorage.key(i)] = sessionStorage.getItem(sessionStorage.key(i));
      const dbs = indexedDB.databases ? await indexedDB.databases() : [];
      for (const { name } of dbs) {
        const db = await new Promise((res, rej) => {
          const r = indexedDB.open(name);
          r.onsuccess = () => res(r.result);
          r.onerror = () => rej(r.error);
        });
        out.idb[name] = {};
        for (const store of Array.from(db.objectStoreNames)) {
          out.idb[name][store] = await new Promise((res, rej) => {
            const tx = db.transaction(store, "readonly");
            const os = tx.objectStore(store);
            const keysReq = os.getAllKeys();
            const valsReq = os.getAll();
            tx.oncomplete = () => {
              const keys = keysReq.result;
              res(
                keys.map((k, i) => {
                  const v = valsReq.result[i];
                  const isKey = typeof CryptoKey !== "undefined" && v instanceof CryptoKey;
                  return {
                    key: k,
                    type: isKey ? "CryptoKey" : typeof v,
                    value: isKey
                      ? { extractable: v.extractable, usages: v.usages, algorithm: v.algorithm.name }
                      : v,
                  };
                }),
              );
            };
            tx.onerror = () => rej(tx.error);
          });
        }
        db.close();
      }
      return out;
    });
  },
  async browser_version() {
    return browser.version();
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
    const tab = tabs.get((req.args && req.args.tab) || "main");
    if (!tab) throw new Error(`unknown tab ${req.args && req.args.tab}`);
    page = tab;
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
