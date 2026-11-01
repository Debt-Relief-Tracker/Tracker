// The ONLY place the E2EE UI touches IndexedDB (docs/architecture/0007-e2ee.md,
// "Storage inventory"). Two object stores, both keyed by workspace id:
//
//   device_keys  a NON-EXTRACTABLE AES-GCM CryptoKey ("remember this device")
//   seen         {rev, hash}: last server revision seen and the SHA-256 of its
//                blob, for rollback detection
//
// Nothing else (no plaintext, vault key bytes, passphrase, recovery key, KEK)
// is ever stored. A backend can be injected for the Node tests.

const DB_NAME = "drt-vault"
const STORES = ["device_keys", "seen"]

let backend = null

export function __setBackend(b) {
  backend = b
}

function openDb() {
  return new Promise((resolve, reject) => {
    const req = globalThis.indexedDB.open(DB_NAME, 1)
    req.onupgradeneeded = () => {
      for (const s of STORES) if (!req.result.objectStoreNames.contains(s)) req.result.createObjectStore(s)
    }
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  })
}

function idbBackend() {
  const run = async (store, mode, fn) => {
    const db = await openDb()
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction(store, mode)
        const req = fn(tx.objectStore(store))
        tx.oncomplete = () => resolve(req && req.result)
        tx.onerror = () => reject(tx.error)
        tx.onabort = () => reject(tx.error)
      })
    } finally {
      db.close()
    }
  }
  return {
    get: (store, key) => run(store, "readonly", (s) => s.get(key)),
    put: (store, key, value) => run(store, "readwrite", (s) => s.put(value, key)),
    del: (store, key) => run(store, "readwrite", (s) => s.delete(key)),
  }
}

function b() {
  if (!backend) {
    if (!globalThis.indexedDB) {
      const e = new Error("storage")
      e.code = "storage_unavailable"
      throw e
    }
    backend = idbBackend()
  }
  return backend
}

function check(store, key) {
  if (!STORES.includes(store) || typeof key !== "string" || key.length === 0) throw new Error("bad store key")
}

export async function get(store, key) {
  check(store, key)
  return b().get(store, key)
}

export async function put(store, key, value) {
  check(store, key)
  return b().put(store, key, value)
}

export async function del(store, key) {
  check(store, key)
  return b().del(store, key)
}
