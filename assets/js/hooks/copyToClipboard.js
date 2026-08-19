// Copies the element's data-copy value, and says so where the click happened:
// a URL that has to be pasted into someone else's dashboard is worth one less
// chance to mistype.
export default {
  mounted() {
    this.el.addEventListener("click", async (event) => {
      // The button sits inside a <summary>, where a click would otherwise
      // open and close the strip it is in.
      event.preventDefault();
      event.stopPropagation();

      try {
        await navigator.clipboard.writeText(this.el.dataset.copy);
        this.confirm("Copied");
      } catch {
        // Denied permission, or no clipboard at all over plain http.
        this.confirm("Press Ctrl+C");
      }
    });
  },

  confirm(message) {
    const label = this.el.querySelector(".copy-button-text");
    if (!label || this.restoring) return;

    const original = label.textContent;
    this.restoring = true;
    label.textContent = message;
    this.el.classList.add("is-copied");

    setTimeout(() => {
      label.textContent = original;
      this.el.classList.remove("is-copied");
      this.restoring = false;
    }, 1200);
  },
};
