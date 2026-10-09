import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["product", "submit", "warning", "summary", "list"]

  connect() {
    this.update()
  }

  update() {
    const selected = this.productTargets.filter(product => product.checked && !product.disabled)
    this.submitTarget.disabled = selected.length === 0
    this.warningTarget.classList.toggle("hidden", selected.length > 0)
    this.summaryTarget.classList.toggle("hidden", selected.length === 0)
    this.listTarget.replaceChildren(...selected.map(product => {
      const item = document.createElement("li")
      item.className = "text-sm font-medium text-gray-900"
      item.textContent = product.dataset.productName
      return item
    }))
  }

  submit(event) {
    if (this.productTargets.some(product => product.checked && !product.disabled)) return

    event.preventDefault()
    this.warningTarget.classList.remove("hidden")
    this.productTargets.find(product => !product.disabled)?.focus()
  }
}
