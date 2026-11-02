// Run: (cd assets && node --test test/)   -- also run by `mix test`
// (test/debt_relief_tracker/crypto_node_test.exs).
import test from "node:test"
import assert from "node:assert/strict"
import nodeCrypto from "node:crypto"
import { readFileSync } from "node:fs"
import { argon2id } from "hash-wasm"
import * as F from "../js/crypto_facade.mjs"
import holo from "../js/crypto_facade.mjs"

const hex = (h) => Uint8Array.from(h.match(/../g) || [], (b) => parseInt(b, 16))
const toHex = (b) => Buffer.from(b).toString("hex")
const b64 = (bytes) => F.bytesToB64u(bytes)
const unb64 = (s) => F.b64uToBytes(s)
const utf8 = (s) => new TextEncoder().encode(s)

async function rejectsWith(promise, code) {
  await assert.rejects(promise, (e) => e instanceof F.CryptoError && e.code === code && e.message === code)
}

// ---- known-answer: AES-256-GCM (McGrew & Viega GCM spec, test cases 13-16) ----
const K0 = "00".repeat(32)
const K1 = "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"
const IV1 = "cafebabefacedbaddecaf888"
const P1 =
  "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"
const AAD1 = "feedfacedeadbeeffeedfacedeadbeefabaddad2"
const GCM_VECTORS = [
  { name: "case 13 (empty PT)", key: K0, iv: "00".repeat(12), pt: "", aad: "", ct: "", tag: "530f8afbc74536b9a963b4f1c4cb738b" },
  { name: "case 14 (16 zero bytes)", key: K0, iv: "00".repeat(12), pt: "00".repeat(16), aad: "", ct: "cea7403d4d606b6e074ec5d3baf39d18", tag: "d0d1c8a799996bf0265b98b5d48ab919" },
  {
    name: "case 15 (64 bytes, no AAD)", key: K1, iv: IV1, pt: P1, aad: "",
    ct: "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad",
    tag: "b094dac5d93471bdec1a502270e3cc6c",
  },
  {
    name: "case 16 (60 bytes, with AAD)", key: K1, iv: IV1, pt: P1.slice(0, 120), aad: AAD1,
    ct: "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662",
    tag: "76fc6ece0f4e1768cddf8853bb2d551b",
  },
]
for (const v of GCM_VECTORS) {
  test(`AES-256-GCM KAT: ${v.name}`, async () => {
    const out = await F.__testOnlyEncryptWithIv(b64(hex(v.key)), b64(hex(v.iv)), b64(hex(v.pt)), b64(hex(v.aad)))
    assert.equal(toHex(unb64(out)), v.ct + v.tag)
  })
}

// ---- known-answer: HKDF-SHA256 (RFC 5869 test cases 1 and 3) ----
test("HKDF-SHA256 RFC 5869 test case 1", async () => {
  const out = await F.hkdfSha256B64u(
    b64(hex("0b".repeat(22))), b64(hex("000102030405060708090a0b0c")), b64(hex("f0f1f2f3f4f5f6f7f8f9")), 42)
  assert.equal(toHex(unb64(out)),
    "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
})
test("HKDF-SHA256 RFC 5869 test case 3 (empty salt and info)", async () => {
  const out = await F.hkdfSha256B64u(b64(hex("0b".repeat(22))), "", "", 42)
  assert.equal(toHex(unb64(out)),
    "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
})

// ---- known-answer: SHA-256 ----
test("SHA-256 FIPS 180 'abc' and empty string", async () => {
  assert.equal(toHex(unb64(await F.sha256B64u("abc"))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  assert.equal(toHex(unb64(await F.sha256B64u(""))), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
})

// ---- known-answer: Argon2id ----
// RFC 9106 section 5.3 uses a secret and associated data, which hash-wasm's
// API cannot express (it has `secret` but no associated-data input). So:
//  (1) the RFC vector is checked against Node's OpenSSL Argon2id (an
//      independent implementation) to pin that reference as correct;
//  (2) hash-wasm is checked against the same implementation on the same
//      parameters minus AD (and with the RFC's secret, which it supports),
//      and at the facade's real 64 MiB / 3 / 1 parameters.
test("Argon2id: RFC 9106 5.3 vector is reproduced by Node's independent implementation", () => {
  const tag = nodeCrypto.argon2Sync("argon2id", {
    message: Buffer.alloc(32, 1), nonce: Buffer.alloc(16, 2), parallelism: 4, tagLength: 32,
    memory: 32, passes: 3, secret: Buffer.alloc(8, 3), associatedData: Buffer.alloc(12, 4),
  })
  assert.equal(tag.toString("hex"), "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
})
test("Argon2id: hash-wasm matches the independent implementation (RFC 9106 inputs without AD)", async () => {
  const common = { message: Buffer.alloc(32, 1), nonce: Buffer.alloc(16, 2), parallelism: 4, tagLength: 32, memory: 32, passes: 3 }
  const ref = nodeCrypto.argon2Sync("argon2id", { ...common, secret: Buffer.alloc(8, 3) }).toString("hex")
  const got = await argon2id({
    password: new Uint8Array(32).fill(1), salt: new Uint8Array(16).fill(2), secret: new Uint8Array(8).fill(3),
    iterations: 3, parallelism: 4, memorySize: 32, hashLength: 32, outputType: "hex",
  })
  assert.equal(got, ref)
  const noSecret = await argon2id({
    password: new Uint8Array(32).fill(1), salt: new Uint8Array(16).fill(2),
    iterations: 3, parallelism: 4, memorySize: 32, hashLength: 32, outputType: "hex",
  })
  assert.equal(noSecret, "03aab965c12001c9d7d0d2de33192c0494b684bb148196d73c1df1acaf6d0c2e")
})
test("Argon2id: facade KEK at default 64 MiB / 3 / 1 matches the independent implementation", async () => {
  const salt = unb64(await F.newSaltB64u())
  const kek = await F.derivePassphraseKek("correct horse battery staple", b64(salt), 65536, 3, 1)
  const ref = nodeCrypto.argon2Sync("argon2id", {
    message: Buffer.from("correct horse battery staple".normalize("NFKC"), "utf8"),
    nonce: Buffer.from(salt), parallelism: 1, tagLength: 32, memory: 65536, passes: 3,
  })
  assert.equal(toHex(unb64(kek)), ref.toString("hex"))
})
test("Argon2id: passphrase is NFKC-normalised; params as numeric strings work", async () => {
  const salt = b64(new Uint8Array(16).fill(9))
  const a = await F.derivePassphraseKek("café", salt, 1024, 1, 1)
  const b = await F.derivePassphraseKek("café", salt, "1024", "1", "1")
  const c = await F.derivePassphraseKek("ｃａｆé", salt, 1024, 1, 1) // fullwidth "caf" + e-acute
  assert.equal(a, b)
  assert.equal(a, c)
  assert.notEqual(a, await F.derivePassphraseKek("cafe", salt, 1024, 1, 1))
  assert.notEqual(a, await F.derivePassphraseKek("café", b64(new Uint8Array(16).fill(8)), 1024, 1, 1))
  assert.notEqual(a, await F.derivePassphraseKek("café", salt, 1024, 2, 1))
})
test("Argon2id: absurd or invalid params are rejected", async () => {
  const salt = b64(new Uint8Array(16).fill(1))
  const bad = [
    [262145, 3, 1], [1048577, 3, 1], [65536, 11, 1], [65536, 3, 5], [65536, 21, 1], [65536, 3, 17], [0, 3, 1], [65536, 0, 1], [65536, 3, 0],
    [-1, 3, 1], [65536, 1.5, 1], [NaN, 3, 1], ["abc", 3, 1], [4, 3, 1], [Infinity, 3, 1],
  ]
  for (const [m, t, p] of bad) await rejectsWith(F.derivePassphraseKek("pw", salt, m, t, p), "bad_params")
  await rejectsWith(F.derivePassphraseKek("pw", b64(new Uint8Array(4)), 1024, 1, 1), "bad_params") // short salt
  await rejectsWith(F.derivePassphraseKek("", salt, 1024, 1, 1), "bad_input")
  await rejectsWith(F.derivePassphraseKek("pw", "not base64!", 1024, 1, 1), "bad_input")
})

// ---- base32 / recovery key ----
test("base32 RFC 4648 vectors (unpadded) and round trip", () => {
  const v = { "": "", f: "MY", fo: "MZXQ", foo: "MZXW6", foob: "MZXW6YQ", fooba: "MZXW6YTB", foobar: "MZXW6YTBOI" }
  for (const [plain, enc] of Object.entries(v)) assert.equal(F.base32Encode(utf8(plain)), enc)
  for (let n = 0; n < 40; n++) {
    const bytes = nodeCrypto.randomBytes(n)
    assert.deepEqual(Buffer.from(F.base32Decode(F.base32Encode(bytes))), bytes)
  }
})
const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
test("recovery key: format with checksum, round trip, tolerant parse", async () => {
  const text = await F.generateRecoveryKey()
  assert.match(text, /^([A-Z2-7]{4}-){13}[A-Z2-7]{4}$/)
  const raw = await F.parseRecoveryKey(text)
  assert.equal(unb64(raw).length, 32)
  assert.equal(await F.formatRecoveryKey(raw), text)
  // checksum = first 20 bits of SHA-256("drt-recovery-check-v1" || key), base32
  const digest = nodeCrypto.createHash("sha256").update(Buffer.concat([Buffer.from("drt-recovery-check-v1"), Buffer.from(unb64(raw))])).digest()
  const bits = (digest[0] << 12) | (digest[1] << 4) | (digest[2] >> 4)
  const check = [15, 10, 5, 0].map((sh) => B32[(bits >> sh) & 31]).join("")
  assert.equal(text.replace(/-/g, "").slice(52), check)
  assert.equal(text.replace(/-/g, "").slice(0, 52), F.base32Encode(unb64(raw)))
  for (const variant of [text.toLowerCase(), text.replace(/-/g, " "), text.replace(/-/g, ""), "  " + text.replace(/-/g, "\n") + " ", text.replace(/-/g, " - ")]) {
    assert.equal(await F.parseRecoveryKey(variant), raw)
  }
  // KEK unchanged by the checksum: HKDF of the 32 key bytes.
  const kek = await F.deriveRecoveryKek(text)
  assert.equal(kek, await F.hkdfSha256B64u(raw, "", b64(utf8("drt-kek-v1")), 32))
  assert.notEqual(kek, await F.deriveRecoveryKek(await F.generateRecoveryKey()))
})
test("recovery key: every single-character substitution at every position is rejected", async () => {
  const flat = (await F.generateRecoveryKey()).replace(/-/g, "")
  assert.equal(flat.length, 56)
  for (let i = 0; i < flat.length; i++) {
    const others = [...B32].filter((c) => c !== flat[i])
    for (const sub of [others[0], others[7], others[others.length - 1]]) {
      await rejectsWith(F.parseRecoveryKey(flat.slice(0, i) + sub + flat.slice(i + 1)), "bad_recovery_key")
    }
  }
})
test("recovery key: transposed adjacent chars, wrong length, bad characters rejected", async () => {
  const flat = (await F.generateRecoveryKey()).replace(/-/g, "")
  let swapped = 0
  for (let i = 0; i < flat.length - 1; i++) {
    if (flat[i] === flat[i + 1]) continue
    const t = flat.slice(0, i) + flat[i + 1] + flat[i] + flat.slice(i + 2)
    await rejectsWith(F.parseRecoveryKey(t), "bad_recovery_key")
    swapped++
  }
  assert.ok(swapped > 40)
  const bad = [
    "", flat.slice(1), flat.slice(0, 55), flat + "A", flat.slice(0, 52), // old 52-char form is not accepted
    flat.slice(0, 55) + "1", flat.slice(0, 55) + "0", flat.slice(0, 55) + "8", flat.slice(0, 55) + "=",
    flat.slice(0, 54) + "!A", "A".repeat(56), "\u00e9".repeat(56),
  ]
  for (const b of bad) await rejectsWith(F.parseRecoveryKey(b), "bad_recovery_key")
  await rejectsWith(F.deriveRecoveryKek("nope"), "bad_recovery_key")
  await rejectsWith(F.deriveRecoveryKek(flat.slice(0, 55) + (flat[55] === "A" ? "B" : "A")), "bad_recovery_key")
  await rejectsWith(F.parseRecoveryKey(null), "bad_recovery_key")
})
const PW12 = "twelve chars!"
test("passphrase KEK for NEW wraps enforces the floor; unwrap-time derivation does not", async () => {
  const salt16 = b64(new Uint8Array(16).fill(5))
  const ok = await F.deriveNewPassphraseKek(PW12, salt16, 65536, 3, 1)
  assert.equal(ok, await F.derivePassphraseKek(PW12, salt16, 65536, 3, 1))
  await rejectsWith(F.deriveNewPassphraseKek(PW12, salt16, 65535, 3, 1), "bad_params")
  await rejectsWith(F.deriveNewPassphraseKek(PW12, salt16, 65536, 2, 1), "bad_params")
  await rejectsWith(F.deriveNewPassphraseKek(PW12, b64(new Uint8Array(15)), 65536, 3, 1), "bad_params")
  await rejectsWith(F.deriveNewPassphraseKek(PW12, salt16, 262145, 3, 1), "bad_params") // sanity bound still applies
  await rejectsWith(F.deriveNewPassphraseKek(PW12, salt16, 65536, 11, 1), "bad_params")
  // above the floor is fine
  await F.deriveNewPassphraseKek(PW12, salt16, 65536, 4, 1)
  // unwrap side: low stored params (within sanity bounds) still derive
  assert.equal(unb64(await F.derivePassphraseKek("pw", salt16, 1024, 1, 1)).length, 32)
  assert.equal(unb64(await F.derivePassphraseKek("pw", b64(new Uint8Array(8)), 1024, 1, 1)).length, 32)
  })

// ---- documents ----
const WS = "ws-123"
test("document round trip, envelope format, unicode", async () => {
  const vk = await F.generateVaultKey()
  assert.equal(unb64(vk).length, 32)
  for (const pt of ["", "{\"debts\":[]}", "héllo \u{1F4B8} ☃".repeat(1000)]) {
    const env = await F.encryptDocument(vk, WS, 7, pt)
    assert.match(env, /^v1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]+$/)
    assert.equal(unb64(env.split(".")[1]).length, 12)
    assert.equal(unb64(env.split(".")[2]).length, utf8(pt).length + 16)
    assert.equal(await F.decryptDocument(vk, WS, 7, env), pt)
    assert.equal(await F.decryptDocument(vk, WS, "7", env), pt)
  }
})
test("document: wrong key / workspace / revision fail with the generic error", async () => {
  const vk = await F.generateVaultKey()
  const env = await F.encryptDocument(vk, WS, 7, "secret")
  await rejectsWith(F.decryptDocument(await F.generateVaultKey(), WS, 7, env), "decrypt_failed")
  await rejectsWith(F.decryptDocument(vk, "ws-124", 7, env), "decrypt_failed")
  await rejectsWith(F.decryptDocument(vk, WS, 8, env), "decrypt_failed")
  await rejectsWith(F.decryptDocument(vk, WS, 0, env), "decrypt_failed")
})
test("document AAD is exactly UTF8('drt-vault-v1') 00 ws 00 String(rev)", async () => {
  const vk = unb64(await F.generateVaultKey())
  const env = await F.encryptDocument(b64(vk), WS, 42, "x")
  const [, iv, ct] = env.split(".")
  const aad = Buffer.concat([Buffer.from("drt-vault-v1"), Buffer.from([0]), Buffer.from(WS), Buffer.from([0]), Buffer.from("42")])
  const d = nodeCrypto.createDecipheriv("aes-256-gcm", vk, unb64(iv))
  const c = Buffer.from(unb64(ct))
  d.setAAD(aad)
  d.setAuthTag(c.subarray(c.length - 16))
  assert.equal(Buffer.concat([d.update(c.subarray(0, c.length - 16)), d.final()]).toString(), "x")
})
test("document: every single-bit flip in IV, ciphertext and tag is rejected", async () => {
  const vk = await F.generateVaultKey()
  const env = await F.encryptDocument(vk, WS, 1, "twenty bytes of data")
  const [v, ivS, ctS] = env.split(".")
  const iv = unb64(ivS), ct = unb64(ctS)
  let n = 0
  for (const [which, bytes] of [["iv", iv], ["ct", ct]]) {
    for (let bit = 0; bit < bytes.length * 8; bit++) {
      const m = Uint8Array.from(bytes)
      m[bit >> 3] ^= 1 << (bit & 7)
      const tampered = which === "iv" ? `${v}.${b64(m)}.${ctS}` : `${v}.${ivS}.${b64(m)}`
      await rejectsWith(F.decryptDocument(vk, WS, 1, tampered), "decrypt_failed")
      n++
    }
  }
  assert.equal(n, (12 + 20 + 16) * 8)
  assert.equal(await F.decryptDocument(vk, WS, 1, env), "twenty bytes of data") // untouched still ok
})
test("document: truncated / garbage / malformed envelopes give the same generic error", async () => {
  const vk = await F.generateVaultKey()
  const env = await F.encryptDocument(vk, WS, 1, "hello")
  const [v, iv, ct] = env.split(".")
  const bad = [
    "", "v1", "v1..", "v1.a.b", "garbage", "v2." + iv + "." + ct, `${v}.${iv}`, `${v}.${iv}.${ct}.extra`,
    `${v}.${iv}.${ct.slice(0, -1)}`, `${v}.${iv}.${ct.slice(0, 10)}`, `${v}.${iv.slice(0, 10)}.${ct}`,
    `${v}.${iv}.`, `${v}..${ct}`, `${v}.${iv}.${ct}=`, `${v}.${iv}.${ct}!!`, "\u0000", "v1." + "A".repeat(10000),
    null, undefined, 42, {},
  ]
  for (const b of bad) await rejectsWith(F.decryptDocument(vk, WS, 1, b), "decrypt_failed")
  // a valid-looking envelope encrypted under a different key
  await rejectsWith(F.decryptDocument(vk, WS, 1, await F.encryptDocument(await F.generateVaultKey(), WS, 1, "hello")), "decrypt_failed")
})
test("document: invalid caller input is bad_input, not a crash", async () => {
  const vk = await F.generateVaultKey()
  await rejectsWith(F.encryptDocument("short", WS, 1, "x"), "bad_input")
  await rejectsWith(F.encryptDocument(b64(new Uint8Array(16)), WS, 1, "x"), "bad_input")
  await rejectsWith(F.encryptDocument(vk, "", 1, "x"), "bad_input")
  await rejectsWith(F.encryptDocument(vk, "a\u0000b", 1, "x"), "bad_input")
  await rejectsWith(F.encryptDocument(vk, WS, -1, "x"), "bad_input")
  await rejectsWith(F.encryptDocument(vk, WS, 1.5, "x"), "bad_input")
  await rejectsWith(F.encryptDocument(vk, WS, "01", "x"), "bad_input")
  await rejectsWith(F.encryptDocument(vk, WS, 1, 5), "bad_input")
})
test("IV uniqueness: 20,000 encryptions of the same key+plaintext all have distinct IVs and ciphertexts", async () => {
  const vk = await F.generateVaultKey()
  const ivs = new Set(), cts = new Set()
  for (let i = 0; i < 20000; i++) {
    const [, iv, ct] = (await F.encryptDocument(vk, WS, 1, "same plaintext")).split(".")
    ivs.add(iv)
    cts.add(ct)
  }
  assert.equal(ivs.size, 20000)
  assert.equal(cts.size, 20000)
})

// ---- wraps ----
test("wrap/unwrap round trip for each kind", async () => {
  const vk = await F.generateVaultKey()
  for (const kind of ["passphrase", "passkey", "recovery"]) {
    const kek = b64(nodeCrypto.randomBytes(32))
    const w = await F.wrapVaultKey(kek, vk, WS, "wrap-1", kind)
    assert.match(w, /^v1\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{64}$/) // 32 + 16 tag bytes
    assert.equal(await F.unwrapVaultKey(kek, w, WS, "wrap-1", kind), vk)
  }
})
test("unwrap fails for wrong KEK, workspace, wrapId, kind (generic error)", async () => {
  const vk = await F.generateVaultKey()
  const kek = b64(nodeCrypto.randomBytes(32))
  const w = await F.wrapVaultKey(kek, vk, WS, "wrap-1", "passphrase")
  await rejectsWith(F.unwrapVaultKey(b64(nodeCrypto.randomBytes(32)), w, WS, "wrap-1", "passphrase"), "decrypt_failed")
  await rejectsWith(F.unwrapVaultKey(kek, w, "other", "wrap-1", "passphrase"), "decrypt_failed")
  await rejectsWith(F.unwrapVaultKey(kek, w, WS, "wrap-2", "passphrase"), "decrypt_failed")
  for (const k of ["passkey", "recovery"]) await rejectsWith(F.unwrapVaultKey(kek, w, WS, "wrap-1", k), "decrypt_failed")
  await rejectsWith(F.unwrapVaultKey(kek, w, WS, "wrap-1", "bogus"), "bad_input")
  // A document envelope is not a wrap and vice versa (different AAD domain).
  const doc = await F.encryptDocument(vk, WS, 1, "x")
  await rejectsWith(F.unwrapVaultKey(vk, doc, WS, "wrap-1", "passphrase"), "decrypt_failed")
  await rejectsWith(F.decryptDocument(kek, WS, 1, w), "decrypt_failed")
})
test("wrap AAD is exactly 'drt-wrap-v1' 00 ws 00 wrapId 00 kind", async () => {
  const kek = nodeCrypto.randomBytes(32), vk = nodeCrypto.randomBytes(32)
  const w = await F.wrapVaultKey(b64(kek), b64(vk), WS, "w9", "recovery")
  const [, iv, ct] = w.split(".")
  const aad = Buffer.concat([Buffer.from("drt-wrap-v1\0"), Buffer.from(WS), Buffer.from([0]), Buffer.from("w9"), Buffer.from([0]), Buffer.from("recovery")])
  const c = Buffer.from(unb64(ct))
  const d = nodeCrypto.createDecipheriv("aes-256-gcm", kek, unb64(iv))
  d.setAAD(aad)
  d.setAuthTag(c.subarray(c.length - 16))
  assert.deepEqual(Buffer.concat([d.update(c.subarray(0, c.length - 16)), d.final()]), vk)
})
test("unwrap yielding a non-32-byte plaintext is rejected", async () => {
  // Craft a wrap of 16 bytes with the right AAD via the public encrypt path is impossible;
  // use node to build one and confirm the facade refuses it.
  const kek = nodeCrypto.randomBytes(32), iv = nodeCrypto.randomBytes(12)
  const c = nodeCrypto.createCipheriv("aes-256-gcm", kek, iv)
  c.setAAD(Buffer.from("drt-wrap-v1\0ws\0w\0passkey"))
  const ct = Buffer.concat([c.update(Buffer.alloc(16)), c.final(), c.getAuthTag()])
  await rejectsWith(F.unwrapVaultKey(b64(kek), `v1.${b64(iv)}.${b64(ct)}`, "ws", "w", "passkey"), "decrypt_failed")
})

// ---- misc ----
test("randomBytesB64u / sha256B64u / generateVaultKey basics", async () => {
  assert.equal(unb64(await F.randomBytesB64u(16)).length, 16)
  assert.notEqual(await F.randomBytesB64u(32), await F.randomBytesB64u(32))
  await rejectsWith(F.randomBytesB64u(0), "bad_input")
  await rejectsWith(F.randomBytesB64u(1.5), "bad_input")
  assert.notEqual(await F.generateVaultKey(), await F.generateVaultKey())
})
test("b64u codec is strict", () => {
  for (const s of ["a", "ab=", "a+b", "a/b", "ab cd", "AB"]) assert.throws(() => F.b64uToBytes(s), (e) => e.code === "bad_input")
  assert.equal(b64(F.b64uToBytes("")), "")
})
test("selfTest passes", async () => {
  assert.equal(await F.selfTest(), "ok")
})

// ---- Hologram surface ----
import * as store from "../js/vault_store.mjs"

const mem = new Map()
store.__setBackend({
  get: async (s, k) => mem.get(s + "/" + k),
  put: async (s, k, v) => void mem.set(s + "/" + k, v),
  del: async (s, k) => void mem.delete(s + "/" + k),
})

test("default (Hologram) export exposes ONLY the handle API", async () => {
  assert.equal(await holo.selfTest(), "ok:ok")
  assert.equal(await holo.prfSupported(), "ok:false") // no WebAuthn in Node
  assert.equal(holo.__testOnlyEncryptWithIv, undefined)
  for (const banned of [
    "generateVaultKey", "encryptDocument", "decryptDocument", "wrapVaultKey", "unwrapVaultKey",
    "derivePassphraseKek", "deriveNewPassphraseKek", "deriveRecoveryKek", "parseRecoveryKey",
    "createPasskey", "derivePasskeyKek", "randomBytesB64u", "hkdfSha256B64u",
  ])
    assert.equal(holo[banned], undefined, banned)
  for (const fn of Object.values(holo)) assert.equal(typeof fn, "function")
})

const ok = (r) => {
  assert.match(r, /^ok:/)
  return r.slice(3)
}

test("handles: unknown / locked handle is err:locked, never throws", async () => {
  assert.equal(await holo.vaultEncrypt("nope", WS, 1, "x"), "err:locked")
  assert.equal(await holo.vaultDecrypt("nope", WS, 1, "v1.AA.AA"), "err:locked")
  assert.equal(await holo.vaultWrapRecovery("nope", WS, "w"), "err:locked")
  assert.equal(await holo.vaultActive("nope"), "ok:false")
})

test("handles: setup -> lock -> unlock by recovery key; document survives; lock wipes", async () => {
  const h = ok(await holo.vaultNew())
  assert.match(h, /^h[A-Za-z0-9_-]{16}$/)
  const [rk, wrapped] = ok(await holo.vaultWrapRecovery(h, WS, "rw1")).split("|")
  assert.match(rk, /^([A-Z2-7]{4}-){13}[A-Z2-7]{4}$/)
  const env = ok(await holo.vaultEncrypt(h, WS, 1, '{"a":"ü"}'))
  assert.equal(ok(await holo.vaultDecrypt(h, WS, 1, env)), '{"a":"ü"}')
  // fresh IV every time
  assert.notEqual(env, ok(await holo.vaultEncrypt(h, WS, 1, '{"a":"ü"}')))
  // wrong revision / workspace -> the one generic error
  assert.equal(await holo.vaultDecrypt(h, WS, 2, env), "err:decrypt_failed")
  assert.equal(await holo.vaultDecrypt(h, "other", 1, env), "err:decrypt_failed")
  assert.equal(await holo.vaultDecrypt(h, WS, 1, env.slice(0, -4) + "AAAA"), "err:decrypt_failed")

  assert.equal(await holo.vaultLock(h), "ok:locked")
  assert.equal(await holo.vaultActive(h), "ok:false")
  assert.equal(await holo.vaultDecrypt(h, WS, 1, env), "err:locked")

  // typo vs wrong key
  assert.equal(await holo.vaultUnlockRecovery("nonsense", WS, "rw1", wrapped), "err:bad_recovery_key")
  const other = await F.generateRecoveryKey()
  assert.equal(await holo.vaultUnlockRecovery(other, WS, "rw1", wrapped), "err:decrypt_failed")
  assert.equal(await holo.vaultUnlockRecovery(rk, WS, "rw2", wrapped), "err:decrypt_failed") // wrong wrap id (AAD)
  const h2 = ok(await holo.vaultUnlockRecovery(rk.toLowerCase().replaceAll("-", " "), WS, "rw1", wrapped))
  assert.notEqual(h2, h)
  assert.equal(ok(await holo.vaultDecrypt(h2, WS, 1, env)), '{"a":"ü"}')
  assert.equal(await holo.vaultLockAll(), "ok:locked")
  assert.equal(await holo.vaultActive(h2), "ok:false")
})

test("handles: passphrase wrap uses the 64MiB/3/16-byte floor and stored params on unlock", async () => {
  const h = ok(await holo.vaultNew())
  const [salt, kdf, wrapped] = ok(await holo.vaultWrapPassphrase(h, "correct horse battery", WS, "pw1")).split("|")
  assert.equal(unb64(salt).length, 16)
  assert.deepEqual(JSON.parse(kdf), { memoryKiB: 65536, iterations: 3, parallelism: 1 })
  const env = ok(await holo.vaultEncrypt(h, WS, 7, "doc"))
  assert.equal(await holo.vaultUnlockPassphrase("wrong wrong wrong", WS, "pw1", salt, kdf, wrapped), "err:decrypt_failed")
  assert.equal(await holo.vaultUnlockPassphrase("correct horse battery", WS, "pw1", salt, "not json", wrapped), "err:bad_params")
  assert.equal(
    await holo.vaultUnlockPassphrase("correct horse battery", WS, "pw1", salt, '{"memoryKiB":99999999,"iterations":3,"parallelism":1}', wrapped),
    "err:bad_params",
  )
  const h2 = ok(await holo.vaultUnlockPassphrase("correct horse battery", WS, "pw1", salt, kdf, wrapped))
  assert.equal(ok(await holo.vaultDecrypt(h2, WS, 7, env)), "doc")
  await holo.vaultLockAll()
})

test("handles: remembered device session decrypts but cannot manage methods", async () => {
  const h = ok(await holo.vaultNew())
  const env = ok(await holo.vaultEncrypt(h, WS, 3, "remember me"))
  assert.equal(await holo.deviceHas(WS), "ok:false")
  assert.equal(await holo.deviceUnlock(WS), "err:decrypt_failed")
  assert.equal(await holo.deviceRemember(h, WS), "ok:remembered")
  assert.equal(await holo.deviceHas(WS), "ok:true")
  const stored = mem.get("device_keys/" + WS)
  assert.equal(stored.extractable, false)
  assert.deepEqual([...stored.usages].sort(), ["decrypt", "encrypt"])
  await assert.rejects(crypto.subtle.exportKey("raw", stored))
  await holo.vaultLockAll()
  const d = ok(await holo.deviceUnlock(WS))
  assert.equal(ok(await holo.vaultDecrypt(d, WS, 3, env)), "remember me")
  assert.equal(ok(await holo.vaultEncrypt(d, WS, 4, "x")).startsWith("v1."), true)
  assert.equal(await holo.vaultCanManage(d), "ok:false")
  assert.equal(await holo.vaultWrapRecovery(d, WS, "r"), "err:locked")
  assert.equal(await holo.vaultWrapPassphrase(d, "long enough passphrase", WS, "p"), "err:locked")
  // locked marker: non-secret, per workspace, independent of the rev/hash record
  assert.equal(await holo.deviceIsLocked(WS), "ok:false")
  await holo.seenRecord(WS, 5, "blobM")
  assert.equal(await holo.deviceMarkLocked(WS), "ok:marked")
  assert.equal(await holo.deviceIsLocked(WS), "ok:true")
  assert.equal(await holo.deviceIsLocked("other-ws"), "ok:false")
  assert.equal(await holo.seenCheck(WS, 5, "blobM"), "ok:ok") // rev/hash record untouched
  assert.equal(await holo.deviceClearLocked(WS), "ok:cleared")
  assert.equal(await holo.deviceIsLocked(WS), "ok:false")
  assert.equal(await holo.seenCheck(WS, 5, "blobM"), "ok:ok")
  await holo.deviceMarkLocked(WS)
  assert.equal(await holo.deviceForget(WS), "ok:forgotten") // removes key AND marker
  assert.equal(await holo.deviceHas(WS), "ok:false")
  assert.equal(await holo.deviceIsLocked(WS), "ok:false")
  await holo.vaultLockAll()
})

test("rollback detection: first / ok / lower rev / same rev different blob", async () => {
  await holo.localWipe(WS)
  assert.equal(await holo.seenCheck(WS, 3, "blobA"), "ok:first")
  assert.equal(await holo.seenRecord(WS, 3, "blobA"), "ok:recorded")
  assert.equal(await holo.seenCheck(WS, 3, "blobA"), "ok:ok")
  assert.equal(await holo.seenCheck(WS, 4, "blobB"), "ok:ok")
  assert.equal(await holo.seenCheck(WS, 2, "blobZ"), "ok:rollback")
  assert.equal(await holo.seenCheck(WS, 3, "blobEVIL"), "ok:rollback")
  assert.equal(await holo.seenRecord(WS, 3, "blobEVIL"), "ok:kept") // monotonic: no silent reset
  assert.equal(await holo.seenCheck(WS, 3, "blobEVIL"), "ok:rollback")
  assert.equal(await holo.seenRecord(WS, 2, "blobZ"), "ok:kept") // never lowered by a stale write
  assert.equal(await holo.seenAcknowledge(WS, 3, "blobEVIL"), "ok:acknowledged") // explicit user ack
  assert.equal(await holo.seenCheck(WS, 3, "blobEVIL"), "ok:ok")
  // only a hash is stored, never the blob
  assert.equal(JSON.stringify(mem.get("seen/" + WS)).includes("blobEVIL"), false)
  assert.equal(await holo.localWipe(WS), "ok:wiped")
  assert.equal(await holo.seenCheck(WS, 1, "x"), "ok:first")
})

// ---- hygiene ----
test("facade source: no console output, no storage, no eval", () => {
  const src = readFileSync(new URL("../js/crypto_facade.mjs", import.meta.url), "utf8")
  const code = src.replace(/\/\/.*$/gm, "")
  for (const banned of [/console\./, /localStorage/, /sessionStorage/, /document\.cookie/, /\beval\s*\(/, /new Function/, /\bindexedDB\b/])
    assert.doesNotMatch(code, banned)
})

test("passphrase minimum length (12 code points) is enforced on every NEW-wrap path", async () => {
  const salt16 = b64(new Uint8Array(16).fill(5))
  await rejectsWith(F.deriveNewPassphraseKek("elevenchars", salt16, 65536, 3, 1), "passphrase_too_short")
  await rejectsWith(F.deriveNewPassphraseKek("", salt16, 65536, 3, 1), "passphrase_too_short")
  await rejectsWith(F.deriveNewPassphraseKek(null, salt16, 65536, 3, 1), "passphrase_too_short")
  // astral characters count as one code point each: 11 emoji is too short, 12 is fine
  await rejectsWith(F.deriveNewPassphraseKek("\u{1F600}".repeat(11), salt16, 65536, 3, 1), "passphrase_too_short")
  await F.deriveNewPassphraseKek("\u{1F600}".repeat(12), salt16, 65536, 3, 1)
  const h = ok(await holo.vaultNew())
  assert.equal(await holo.vaultWrapPassphrase(h, "short one", WS, "p1"), "err:passphrase_too_short")
  assert.equal(await holo.vaultWrapPassphrase(h, "", WS, "p1"), "err:passphrase_too_short")
  assert.match(await holo.vaultWrapPassphrase(h, "exactly12chr", WS, "p1"), /^ok:/)
})

test("passkeys require user verification (create + get) and refuse a non-UV assertion", async () => {
  const seen = []
  const ad = (flags) => {
    const a = new Uint8Array(37)
    a[32] = flags
    return a.buffer
  }
  const prf = new Uint8Array(32).fill(7).buffer
  let getFlags = 0x05
  const creds = {
    async create(o) {
      seen.push(["create", o.publicKey.authenticatorSelection.userVerification])
      return { rawId: new Uint8Array([1, 2, 3]).buffer, getClientExtensionResults: () => ({ prf: { enabled: true, results: { first: prf } } }) }
    },
    async get(o) {
      seen.push(["get", o.publicKey.userVerification])
      return { response: { authenticatorData: ad(getFlags) }, getClientExtensionResults: () => ({ prf: { results: { first: prf } } }) }
    },
  }
  const saved = Object.getOwnPropertyDescriptors(globalThis)
  const set = (k, v) => Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true })
  set("PublicKeyCredential", function () {})
  set("navigator", { credentials: creds })
  try {
    const out = await F.createPasskey("", "App", b64(new Uint8Array(16)), "u", "U")
    assert.match(out, /\./)
    await F.derivePasskeyKek(b64(new Uint8Array([1, 2, 3])), "")
    assert.deepEqual(seen, [["create", "required"], ["get", "required"]])
    getFlags = 0x01 // user present but NOT verified
    await rejectsWith(F.derivePasskeyKek(b64(new Uint8Array([1, 2, 3])), ""), "passkey_uv_unsupported")
    // authenticator that cannot do UV: browsers raise ConstraintError
    creds.create = async () => { throw Object.assign(new Error("x"), { name: "ConstraintError" }) }
    await rejectsWith(F.createPasskey("", "App", b64(new Uint8Array(16)), "u", "U"), "passkey_uv_unsupported")
  } finally {
    for (const k of ["PublicKeyCredential", "navigator"]) {
      if (saved[k]) Object.defineProperty(globalThis, k, saved[k])
      else delete globalThis[k]
    }
  }
})
