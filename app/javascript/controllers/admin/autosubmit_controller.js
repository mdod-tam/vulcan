import { Controller } from "@hotwired/stimulus";
import { debounce } from "../../utils/debounce";

export default class extends Controller {
  static values = {
    delay: { type: Number, default: 150 },
  };

  connect() {
    this.debouncedSubmit = debounce(
      this.submit.bind(this),
      this.delayValue
    );
  }

  disconnect() {
    this.debouncedSubmit.cancel();
  }

  search() {
    this.debouncedSubmit();
  }

  submit() {
    this.element.requestSubmit();
  }

}
