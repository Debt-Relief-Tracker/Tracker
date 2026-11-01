// Verifies the crypto facade (bundled with esbuild exactly as Hologram would
// pull in hash-wasm) runs under a strict CSP in headless Chromium, and times
// Argon2id. Prints one JSON report. Not an app server: a throwaway loopback
// static server on a random port.
//
//   node csp_check.mjs <esbuild-binary> <chromium> [runs]
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import http from "node:http";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright-core");
const here = dirname(fileURLToPath(import.meta.url));
const assets = join(here, "../../assets");
const [esbuild, chromiumPath, runsArg] = process.argv.slice(2);
const runs = Number(runsArg || 5);

const dir = mkdtempSync(join(tmpdir(), "csp-check-"));
writeFileSync(join(dir, "entry.mjs"), `import * as F from ${JSON.stringify(join(assets, "js/crypto_facade.mjs"))}; window.__F = F; window.__ready = true;`);
execFileSync(esbuild, [join(dir, "entry.mjs"), "--bundle", "--format=esm", "--minify", `--outfile=${join(dir, "bundle.js")}`], {
  env: { ...process.env, NODE_PATH: join(assets, "node_modules") },
  stdio: ["ignore", "ignore", "inherit"],
});
const bundle = readFileSync(join(dir, "bundle.js"));

function serve(csp) {
  const server = http.createServer((req, res) => {
    const h = { "content-security-policy": csp };
    if (req.url === "/bundle.js") res.writeHead(200, { ...h, "content-type": "text/javascript" }).end(bundle);
    else res.writeHead(200, { ...h, "content-type": "text/html" }).end(`<!doctype html><script type="module" src="/bundle.js"></script>`);
  });
  return new Promise((r) => server.listen(0, "127.0.0.1", () => r(server)));
}

const probe = async (page) => {
  const violations = [];
  page.on("console", (m) => { if (m.type() === "error") violations.push(m.text().slice(0, 160)); });
  page.on("pageerror", (e) => violations.push(String(e.message).slice(0, 160)));
  return violations;
};

async function run(csp, browser, timing) {
  const server = await serve(csp);
  const page = await browser.newPage();
  const errors = await probe(page);
  try {
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForFunction(() => window.__ready, null, { timeout: 5000 });
    const out = await page.evaluate(async ({ timing, runs }) => {
      const F = window.__F;
      const r = {};
      try { r.selfTest = await F.selfTest(); } catch (e) { r.selfTest = "FAIL:" + (e.code || e.message); }
      try {
        const salt = await F.newSaltB64u();
        const times = [];
        for (let i = 0; i < (timing ? runs : 1); i++) {
          const t = performance.now();
          const kek = await F.derivePassphraseKek("correct horse battery staple", salt, 65536, 3, 1);
          times.push(Math.round(performance.now() - t));
          r.kekLen = kek.length;
        }
        r.argon2Ms = times;
      } catch (e) { r.argon2 = "FAIL:" + (e.code || e.name + ":" + e.message.slice(0, 120)); }
      return r;
    }, { timing, runs });
    return { csp, ...out, consoleErrors: errors };
  } finally {
    await page.close();
    server.close();
  }
}

const browser = await chromium.launch({ executablePath: chromiumPath, headless: true, args: ["--no-sandbox"] });
const report = {
  browser: browser.version(),
  withWasmUnsafeEval: await run("default-src 'none'; script-src 'self' 'wasm-unsafe-eval'", browser, true),
  withoutWasmUnsafeEval: await run("default-src 'none'; script-src 'self'", browser, false),
};
await browser.close();
rmSync(dir, { recursive: true, force: true });
console.log(JSON.stringify(report));
