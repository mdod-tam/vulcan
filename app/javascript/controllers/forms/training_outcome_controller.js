import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selection", "panel"]

  connect() {
    this.change()
  }

  change() {
    for (const panel of this.panelTargets) {
      const selected = panel.dataset.outcome === this.selectionTarget.value
      panel.hidden = !selected
      for (const control of panel.querySelectorAll("input, select, textarea, button")) {
        control.disabled = !selected
      }
    }
  }
}
