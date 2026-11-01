// Fast path for DebtReliefTracker.VaultDoc.Json in the browser (ADR 0007).
//
// Hologram's interpreter is far too slow to encode/decode a multi-thousand
// record document in Elixir (see the moduledoc of VaultDoc.Json), so the
// browser delegates to this file. It is a *byte-for-byte equivalent* of the
// pure Elixir implementation, which stays the reference (ExUnit runs it, and
// a browser test compares the two on a fixed script):
//
//   encode: no whitespace, object keys sorted by Unicode code point (= UTF-8
//           byte order), strings through JSON.stringify (escapes only ", \,
//           and U+0000..U+001F as \b \t \n \f \r or lowercase \u00xx),
//           integers only (bigint allowed), no floats.
//   decode: strict JSON without floats, exponents, "-0", leading zeros,
//           duplicate keys, raw control characters or unpaired surrogate
//           escapes; integers must be within +-(2^53 - 1); nesting <= 64,
//           strings <= 1 MiB, input <= 16 MiB. Returns [true, value] or
//           [false] (never throws).
//
// No application logic: generic canonical JSON only.

const MAX_DEPTH = 64;
const MAX_STRING_BYTES = 1048576;
const MAX_INPUT_BYTES = 16777216;
const utf8 = new TextEncoder();

function byteLength(str) {
  return utf8.encode(str).length;
}

function cmpCodePoints(a, b) {
  const ia = a[Symbol.iterator]();
  const ib = b[Symbol.iterator]();
  for (;;) {
    const x = ia.next();
    const y = ib.next();
    if (x.done) return y.done ? 0 : -1;
    if (y.done) return 1;
    const cx = x.value.codePointAt(0);
    const cy = y.value.codePointAt(0);
    if (cx !== cy) return cx < cy ? -1 : 1;
  }
}

function enc(v, out) {
  if (v === null || v === undefined) out.push("null");
  else if (v === true) out.push("true");
  else if (v === false) out.push("false");
  else if (typeof v === "bigint") out.push(v.toString());
  else if (typeof v === "number") {
    if (!Number.isInteger(v)) throw new Error("float");
    out.push(String(v));
  } else if (typeof v === "string") out.push(JSON.stringify(v));
  else if (Array.isArray(v)) {
    out.push("[");
    for (let i = 0; i < v.length; i++) {
      if (i > 0) out.push(",");
      enc(v[i], out);
    }
    out.push("]");
  } else if (typeof v === "object") {
    const keys = Object.keys(v).sort(cmpCodePoints);
    out.push("{");
    for (let i = 0; i < keys.length; i++) {
      if (i > 0) out.push(",");
      out.push(JSON.stringify(keys[i]), ":");
      enc(v[keys[i]], out);
    }
    out.push("}");
  } else throw new Error("unsupported");
}

function encode(value) {
  const out = [];
  enc(value, out);
  return out.join("");
}

class Bad extends Error {}

function decodeText(text) {
  let i = 0;
  const n = text.length;
  const bad = () => {
    throw new Bad();
  };
  const ws = () => {
    while (i < n) {
      const c = text.charCodeAt(i);
      if (c === 32 || c === 9 || c === 10 || c === 13) i++;
      else break;
    }
  };
  const str = () => {
    i++; // opening quote
    let out = "";
    let start = i;
    for (;;) {
      if (i >= n) bad();
      const c = text.charCodeAt(i);
      if (c === 34) {
        out += text.slice(start, i);
        i++;
        break;
      }
      if (c < 32) bad();
      if (c === 92) {
        out += text.slice(start, i);
        i++;
        const e = text[i];
        if (e === '"') out += '"';
        else if (e === "\\") out += "\\";
        else if (e === "/") out += "/";
        else if (e === "b") out += "\b";
        else if (e === "f") out += "\f";
        else if (e === "n") out += "\n";
        else if (e === "r") out += "\r";
        else if (e === "t") out += "\t";
        else if (e === "u") {
          const hi = hex4(i + 1);
          i += 4;
          if (hi >= 0xd800 && hi <= 0xdbff) {
            if (text[i + 1] !== "\\" || text[i + 2] !== "u") bad();
            const lo = hex4(i + 3);
            if (lo < 0xdc00 || lo > 0xdfff) bad();
            i += 6;
            out += String.fromCharCode(hi, lo);
          } else if (hi >= 0xdc00 && hi <= 0xdfff) bad();
          else out += String.fromCharCode(hi);
        } else bad();
        i++;
        start = i;
      } else i++;
    }
    if (out.length * 3 > MAX_STRING_BYTES && byteLength(out) > MAX_STRING_BYTES) bad();
    return out;
  };
  const hex4 = (at) => {
    if (at + 4 > n) bad();
    const s = text.slice(at, at + 4);
    for (let k = 0; k < 4; k++) if (!/[0-9a-fA-F]/.test(s[k])) bad();
    return parseInt(s, 16);
  };
  const num = () => {
    const start = i;
    if (text[i] === "-") i++;
    const d0 = i;
    while (i < n && text.charCodeAt(i) >= 48 && text.charCodeAt(i) <= 57) i++;
    const digits = text.slice(d0, i);
    if (digits === "" || (digits.length > 1 && digits[0] === "0")) bad();
    if (i < n && ".eE+-".includes(text[i])) bad();
    if (text[start] === "-" && digits === "0") bad();
    if (digits.length > 16) bad();
    const v = Number(text.slice(start, i));
    if (!Number.isSafeInteger(v)) bad();
    return v;
  };
  const lit = (word, value) => {
    if (text.startsWith(word, i)) {
      i += word.length;
      return value;
    }
    return bad();
  };
  const val = (depth) => {
    ws();
    if (i >= n) bad();
    const c = text[i];
    if (c === '"') return str();
    if (c === "{") {
      if (depth >= MAX_DEPTH) bad();
      i++;
      const seen = new Map();
      ws();
      if (text[i] === "}") {
        i++;
        return {};
      }
      for (;;) {
        ws();
        if (text[i] !== '"') bad();
        const k = str();
        if (seen.has(k)) bad();
        ws();
        if (text[i] !== ":") bad();
        i++;
        seen.set(k, val(depth + 1));
        ws();
        if (text[i] === ",") i++;
        else if (text[i] === "}") {
          i++;
          break;
        } else bad();
      }
      return Object.fromEntries(seen);
    }
    if (c === "[") {
      if (depth >= MAX_DEPTH) bad();
      i++;
      const arr = [];
      ws();
      if (text[i] === "]") {
        i++;
        return arr;
      }
      for (;;) {
        arr.push(val(depth + 1));
        ws();
        if (text[i] === ",") i++;
        else if (text[i] === "]") {
          i++;
          break;
        } else bad();
      }
      return arr;
    }
    if (c === "t") return lit("true", true);
    if (c === "f") return lit("false", false);
    if (c === "n") return lit("null", null);
    if (c === "-" || (c >= "0" && c <= "9")) return num();
    return bad();
  };
  const v = val(0);
  ws();
  if (i !== n) bad();
  return v;
}

function decode(text) {
  try {
    if (typeof text !== "string" || text.length > MAX_INPUT_BYTES) return [false];
    if (text.length * 3 > MAX_INPUT_BYTES && byteLength(text) > MAX_INPUT_BYTES) return [false];
    return [true, decodeText(text)];
  } catch (_e) {
    return [false];
  }
}

export default {encode, decode};
