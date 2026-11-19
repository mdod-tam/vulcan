import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = ["category", "type"]
  static values = { choices: Object }

  connect() {
    this.update()
  }

  update() {
    const choices = this.choicesValue[this.categoryTarget.value]
    this.typeTargets.forEach(row => {
      const input = row.querySelector("input[type=checkbox]")
      const allowed = !choices || choices.includes(row.dataset.deviceType)
      row.hidden = !allowed && !input.checked
      setVisible(row, !row.hidden, { inlineStyleFallback: false })
      input.disabled = !allowed && !input.checked
    })
  }
}
