// Hands a string to the browser as a file download (Blob + a temporary
// anchor click). Used by the E2EE-mode CSV export: the text is built in the
// browser from the decrypted vault and never touches the server. No inline
// script, no network.

export function download(filename, text, mime, containerSelector) {
  const blob = new Blob([String(text)], { type: String(mime || "text/csv;charset=utf-8") })
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = String(filename)
  a.style.display = "none"
  // The anchor lives INSIDE the caller's dialog: a click on an element outside
  // it would count as a click-outside (Hologram's `$click_outside`) and close
  // the open modal.
  const host = (containerSelector && document.querySelector(containerSelector)) || document.body
  host.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 10000)
  return "ok"
}

export default { download }
