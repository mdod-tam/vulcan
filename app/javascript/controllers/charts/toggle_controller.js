import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["chart", "button"]

  toggle() {
    const hidden = this.chartTarget.classList.toggle("hidden")
    this.buttonTarget.setAttribute("aria-expanded", String(!hidden))
    this.buttonTarget.textContent = hidden ? "Show Chart" : "Hide Chart"
  }
}
