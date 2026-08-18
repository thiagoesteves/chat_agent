// This project is generated with --no-assets, so there is no bundler. The
// Phoenix and LiveView ES module builds are vendored under ./vendor and
// imported directly by the browser. Refresh them with:
//
//   cp deps/phoenix/priv/static/phoenix.mjs priv/static/assets/js/vendor/
//   cp deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js priv/static/assets/js/vendor/
import { Socket } from "./vendor/phoenix.mjs";
import { LiveSocket } from "./vendor/phoenix_live_view.esm.js";
// One file per hook under ./hooks, named after the hook it exports. Without a
// bundler the extension is part of the URL the browser fetches, so keep it.
import AutoDismissFlash from "./hooks/autoDismissFlash.js";

const Hooks = {
  AutoDismissFlash,
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

// Exposed for debugging: liveSocket.enableDebug() in the browser console.
window.liveSocket = liveSocket;

// Click to close a flash on a page with no LiveView, where no hook runs. This
// only reaches the notices present at load, which is all a dead render has;
// inside a LiveView the AutoDismissFlash hook handles the click instead, and
// clears the flash on the server rather than only hiding the element.
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => {
    el.setAttribute("hidden", "");
  });
});
