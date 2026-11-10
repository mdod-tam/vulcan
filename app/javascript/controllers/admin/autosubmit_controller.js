import { Controller } from "@hotwired/stimulus";
import { debounce } from "../../utils/debounce";

export default class extends Controller {
  static values = {
    delay: { type: Number, default: 150 },
  };

  connect() {
    this.debouncedSubmit = debounce(this.submit.bind(this), this.delayValue);
    this.searchFields = new Set();
    this.frame = document.getElementById(this.element.dataset.turboFrame);
    this.beforeFetchRequest = event => {
      if (event.target === this.frame) {
        this.debouncedSubmit.cancel();
        this.searchFields.clear();
      }
    };
    this.beforeFrameRender = this.beforeFrameRender.bind(this);
    this.frame?.addEventListener("turbo:before-fetch-request", this.beforeFetchRequest);
    this.frame?.addEventListener("turbo:before-frame-render", this.beforeFrameRender);
  }

  disconnect() {
    this.debouncedSubmit.cancel();
    this.frame?.removeEventListener("turbo:before-fetch-request", this.beforeFetchRequest);
    this.frame?.removeEventListener("turbo:before-frame-render", this.beforeFrameRender);
  }

  search(event) {
    if (event?.target) this.searchFields.add(event.target);
    this.debouncedSubmit();
  }

  submit(event) {
    const parameter = event?.target.dataset.autosubmitClearParam;
    if (parameter) this.element.elements.namedItem(parameter)?.remove();
    this.debouncedSubmit.cancel();
    this.element.requestSubmit();
  }

  beforeFrameRender(event) {
    if (event.target !== this.frame || !this.frame.contains(this.element)) return;

    const incoming = new Map([...event.detail.newFrame.querySelectorAll("input, select, textarea")].map(input => [input.id, input]));
    const render = event.detail.render;
    event.detail.render = async (...args) => {
      const field = document.activeElement;
      const focused = incoming.has(field?.id) && this.element.contains(field);
      const selection = focused ? [field.selectionStart, field.selectionEnd, field.selectionDirection] : null;
      const pendingSearches = [...this.searchFields]
        .filter(input => incoming.has(input.id) && input.value !== incoming.get(input.id).value)
        .map(input => ({ id: input.id, value: input.value }));
      await render(...args);
      if (!focused && !pendingSearches.length) return;
      await new Promise(requestAnimationFrame);

      const searches = pendingSearches.map(({ id, value }) => {
        const replacement = document.getElementById(id);
        if (!replacement || !this.frame.contains(replacement)) return;
        replacement.value = value;
        return replacement;
      }).filter(Boolean);

      const replacement = focused && document.getElementById(field.id);
      if (replacement && this.frame.contains(replacement) && [document.body, replacement].includes(document.activeElement)) {
        replacement.focus({ preventScroll: true });
        if (selection[0] != null) replacement.setSelectionRange(...selection);
      }
      searches[0]?.dispatchEvent(new Event("input", { bubbles: true }));
    };
  }
}
