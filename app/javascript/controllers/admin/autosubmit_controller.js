import { Controller } from "@hotwired/stimulus";
import { debounce } from "../../utils/debounce";

export default class extends Controller {
  static values = {
    delay: { type: Number, default: 150 },
  };

  connect() {
    this.debouncedSubmit = debounce(this.submit.bind(this), this.delayValue);
    this.frame = document.getElementById(this.element.dataset.turboFrame);
    this.beforeFrameRender = this.beforeFrameRender.bind(this);
    this.frame?.addEventListener("turbo:before-frame-render", this.beforeFrameRender);
  }

  disconnect() {
    this.debouncedSubmit.cancel();
    this.frame?.removeEventListener("turbo:before-frame-render", this.beforeFrameRender);
  }

  search(event) {
    this.searchField = event?.target;
    this.debouncedSubmit();
  }

  submit() {
    this.element.requestSubmit();
  }

  beforeFrameRender(event) {
    const field = document.activeElement;
    if (event.target !== this.frame || !field?.id || !this.element.contains(field) || !this.frame.contains(field)) return;

    const incoming = [...event.detail.newFrame.querySelectorAll("input, select, textarea")].find(input => input.id === field.id);
    if (!incoming) return;

    const render = event.detail.render;
    event.detail.render = async (...args) => {
      const value = field.value;
      const selection = [field.selectionStart, field.selectionEnd, field.selectionDirection];
      const pendingSearch = field === this.searchField && value !== incoming.value;
      await render(...args);
      await new Promise(requestAnimationFrame);

      const replacement = document.getElementById(field.id);
      if (!replacement || !this.frame.contains(replacement)) return;
      if (document.activeElement !== document.body && document.activeElement !== replacement) return;

      if (pendingSearch) replacement.value = value;
      replacement.focus({ preventScroll: true });
      if (selection[0] != null) replacement.setSelectionRange(...selection);
      if (pendingSearch) replacement.dispatchEvent(new Event("input", { bubbles: true }));
    };
  }
}
