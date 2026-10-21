import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selection", "panel", "status"]
  static values = { message: String }

  connect() {
    this.statusTarget.textContent = ""
    this.change()
  }

  change(event) {
    for (const panel of this.panelTargets) {
      const selected = panel.dataset.outcome === this.selectionTarget.value
      panel.hidden = !selected
      for (const control of panel.querySelectorAll("input, select, textarea, button")) {
        control.disabled = !selected
      }
    }

    if (event) {
      this.statusTarget.textContent = this.selectionTarget.value
        ? this.messageValue.replace("__ACTION__", this.selectionTarget.selectedOptions[0].textContent)
        : ""
    }
  }
}
