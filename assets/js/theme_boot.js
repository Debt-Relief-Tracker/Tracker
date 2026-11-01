// Theme boot for the LiveView pages. Loaded synchronously (not deferred) from
// <head> by root.html.heex so the theme is applied before first paint. Lives
// in a file (not an inline <script>) so the strict CSP needs no 'unsafe-inline'.
(() => {
  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem("phx:theme");
      document.documentElement.removeAttribute("data-theme");
    } else {
      localStorage.setItem("phx:theme", theme);
      document.documentElement.setAttribute("data-theme", theme);
    }
  };
  if (!document.documentElement.hasAttribute("data-theme")) {
    // The account's saved theme (if any) wins over this device's.
    setTheme(document.documentElement.dataset.savedTheme || localStorage.getItem("phx:theme") || "system");
  }
  window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"));

  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));
})();
