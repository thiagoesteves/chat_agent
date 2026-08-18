// A flash notice takes itself off the screen after a few seconds, and goes
// immediately when clicked.
//
// Dismissing means telling the server: `lv:clear-flash` is handled natively by
// LiveView, so the message leaves the socket's flash and LiveView removes the
// element. Hiding the node client side instead would leave the flash on the
// server, and the next identical message would produce no diff at all, so it
// would never be seen.
const DISMISS_AFTER_MS = 4000;

const AutoDismissFlash = {
  mounted() {
    this.timer = setTimeout(() => this.dismiss(), DISMISS_AFTER_MS);
    this.el.addEventListener("click", () => this.dismiss());
  },

  destroyed() {
    clearTimeout(this.timer);
  },

  dismiss() {
    clearTimeout(this.timer);
    this.el.classList.add("flash-leaving");

    // The fade is styled in app.css, so its length is read back from there
    // rather than repeated here. A visitor who asked for reduced motion gets
    // 0s and the notice goes at once.
    const fadeMs =
      parseFloat(getComputedStyle(this.el).transitionDuration) * 1000;

    setTimeout(
      () => this.pushEvent("lv:clear-flash", { key: this.el.dataset.flash }),
      fadeMs,
    );
  },
};

export default AutoDismissFlash;
