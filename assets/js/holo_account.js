// Theme + form-POST facade for the Hologram pages (loaded by Holo.Layout;
// NOT part of app.js, which boots a LiveView socket those pages don't have).
//
// Mirrors the inline script in root.html.heex: the account's saved theme
// (rendered by the header as data-saved-theme) wins over this device's
// localStorage, which wins over "system". No app logic lives here -- Elixir
// calls HoloAccount.setTheme / HoloAccount.postForm through JS interop.
(() => {
  const KEY = "phx:theme";

  const read = () => {
    try {
      return localStorage.getItem(KEY);
    } catch (_e) {
      return null;
    }
  };

  const setTheme = (theme) => {
    try {
      if (theme === "system") localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, theme);
    } catch (_e) {
      // storage blocked: the theme still applies for this page view
    }

    if (theme === "system") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", theme);
  };

  // Before first paint: this device's choice.
  setTheme(read() || "system");

  // Once the server-rendered header exists: the account's choice wins.
  document.addEventListener("DOMContentLoaded", () => {
    const el = document.querySelector("[data-saved-theme]");
    const saved = el && el.getAttribute("data-saved-theme");
    if (saved) setTheme(saved);
  });

  window.addEventListener("storage", (e) => {
    if (e.key === KEY) setTheme(e.newValue || "system");
  });

  // A real, full-page form POST (used for log out, which needs the browser
  // to follow the controller's redirect and drop the session cookie).
  const postForm = (action, fields) => {
    const form = document.createElement("form");
    form.method = "post";
    form.action = action;

    Object.keys(fields).forEach((name) => {
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = name;
      input.value = fields[name];
      form.appendChild(input);
    });

    document.body.appendChild(form);
    form.submit();
  };

  window.HoloAccount = { setTheme, postForm };
})();
