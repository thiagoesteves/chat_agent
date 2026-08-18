// Bundled by esbuild into priv/static/assets/js/app.js. Dependencies are
// resolved from deps/ through NODE_PATH, so `phoenix` and `phoenix_live_view`
// are the packages themselves rather than a copy checked in here.

// Handles method=PUT/DELETE on links and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
// One file per hook under ./hooks, named after the hook it exports.
import AutoDismissFlash from "./hooks/autoDismissFlash";

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
