// A link inside a <summary> is still inside the control that opens the strip,
// so a click would follow the link and toggle the strip behind it. Following
// the link is what was asked for; the toggle is not.
export default {
  mounted() {
    this.el.addEventListener("click", (event) => event.stopPropagation());
  },
};
