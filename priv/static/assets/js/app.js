// This project is generated with --no-assets, so there is no bundler. The
// Phoenix and LiveView ES module builds are vendored under ./vendor and
// imported directly by the browser. Refresh them with:
//
//   cp deps/phoenix/priv/static/phoenix.mjs priv/static/assets/js/vendor/
//   cp deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js priv/static/assets/js/vendor/
import { Socket } from "./vendor/phoenix.mjs";
import { LiveSocket } from "./vendor/phoenix_live_view.esm.js";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

// Exposed for debugging: liveSocket.enableDebug() in the browser console.
window.liveSocket = liveSocket;

// Handle flash close
// (you can safely remove this if you don't use the default flash component)
document.querySelectorAll("[role=alert][data-flash]").forEach((el) => {
  el.addEventListener("click", () => {
    el.setAttribute("hidden", "");
  });
});
