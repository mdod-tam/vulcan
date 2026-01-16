import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = {
    delay: { type: Number, default: 300 },
  };

  connect() {
    this.debouncedSubmit = this.debounce(
      this.submit.bind(this),
      this.delayValue
    );
  }

  search() {
    this.debouncedSubmit();
  }

  submit() {
    this.element.requestSubmit();
  }

  debounce(func, wait) {
    let timeout;
    return function (...args) {
      const later = () => {
        clearTimeout(timeout);
        func.apply(this, args);
      };
      clearTimeout(timeout);
      timeout = setTimeout(later, wait);
    };
  }
}
