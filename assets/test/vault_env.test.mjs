// Pure parts of the browser environment facade (no DOM needed).
import test from "node:test"
import assert from "node:assert/strict"
import env, { idleRemaining, nowIso, todayIso, randomUuid, setDirty, broadcast } from "../js/vault_env.mjs"
import { copyText, CLIPBOARD_CLEAR_MS } from "../js/vault_env.mjs"
import { readFileSync } from "node:fs"

test("idleRemaining counts down to the timeout", () => {
  assert.equal(idleRemaining(1000, 0, 5000), 4000)
  assert.equal(idleRemaining(5000, 0, 5000), 0)
  assert.ok(idleRemaining(6000, 0, 5000) < 0)
  assert.equal(idleRemaining(6000, 2000, 5000), 1000, "activity moves the deadline")
})

test("clock and id helpers", () => {
  assert.match(nowIso(), /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/)
  assert.match(todayIso(), /^\d{4}-\d\d-\d\d$/)
  const a = randomUuid()
  assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
  assert.notEqual(a, randomUuid())
})

test("setDirty and broadcast are safe without a page", () => {
  assert.equal(setDirty(true), "ok")
  assert.equal(setDirty("false"), "ok")
  assert.equal(broadcast("locked"), "ok") // no channel: no-op
  assert.equal(broadcast("anything"), "ok")
  assert.equal(typeof env.envInit, "function")
})

test("source hygiene: no storage, cookies, eval or secrets API", () => {
  const code = readFileSync(new URL("../js/vault_env.mjs", import.meta.url), "utf8").replace(/\/\/.*$/gm, "")
  for (const banned of [/localStorage/, /sessionStorage/, /document\.cookie/, /\beval\s*\(/, /new Function/, /indexedDB/, /console\./])
    assert.doesNotMatch(code, banned)
})

test("copyText clears the clipboard after 60 s, best effort, errors swallowed", async (t) => {
  const writes = []
  let fail = false
  t.mock.timers.enable({ apis: ["setTimeout"] })
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { clipboard: { writeText: (x) => (fail ? Promise.reject(new Error("no focus")) : (writes.push(x), Promise.resolve())) } },
  })
  assert.equal(copyText("secret key"), "ok")
  assert.deepEqual(writes, ["secret key"])
  t.mock.timers.tick(CLIPBOARD_CLEAR_MS - 1)
  assert.deepEqual(writes, ["secret key"])
  t.mock.timers.tick(1)
  assert.deepEqual(writes, ["secret key", ""])
  fail = true
  assert.equal(copyText("again"), "ok")
  t.mock.timers.tick(CLIPBOARD_CLEAR_MS) // rejected write must not throw
  delete globalThis.navigator
})
