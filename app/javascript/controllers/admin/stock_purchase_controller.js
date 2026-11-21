import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rows", "template"]

  add() {
    const index = this.rowsTarget.childElementCount
    this.rowsTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML.replaceAll("__BATCH_INDEX__", index))
    this.rowsTarget.lastElementChild.querySelector('input[type="number"]').focus()
  }
}
