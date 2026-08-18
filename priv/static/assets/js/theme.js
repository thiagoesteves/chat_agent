// Applies the saved theme before first paint, so there is no flash of the
// wrong theme. Loaded synchronously from <head>, ahead of the stylesheets.
//
// "system" removes the attribute and lets prefers-color-scheme decide;
// "light" and "dark" pin it. The choice is persisted in localStorage and
// mirrored across tabs.
(() => {
  const KEY = "theme";

  const applyTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem(KEY);
      document.documentElement.removeAttribute("data-theme");
    } else {
      localStorage.setItem(KEY, theme);
      document.documentElement.setAttribute("data-theme", theme);
    }
  };

  applyTheme(localStorage.getItem(KEY) || "system");

  window.addEventListener("storage", (event) => {
    if (event.key === KEY) applyTheme(event.newValue || "system");
  });

  // Delegated so it works on any page carrying the toggle, LiveView or not.
  document.addEventListener("click", (event) => {
    const button = event.target.closest("[data-set-theme]");
    if (button) applyTheme(button.dataset.setTheme);
  });
})();
