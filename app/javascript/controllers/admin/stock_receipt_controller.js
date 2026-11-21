import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["row", "quantity", "identifiers", "submit"]

  connect() { this.update() }

  remaining(event) {
    const input = event.target.closest("tr").querySelector('input[type="number"]')
    input.value = input.max
    this.update()
  }

  update() {
    let total = 0
    this.rowTargets.forEach((row) => {
      const quantity = Math.max(0, Number.parseInt(row.querySelector('input[type="number"]').value, 10) || 0)
      total += quantity
      const container = this.identifiersTargets.find((entry) => entry.dataset.batch === row.dataset.batch)
      container?.querySelectorAll("[data-unit-index]").forEach((unit) => {
        const selected = Number(unit.dataset.unitIndex) < quantity
        unit.hidden = !selected
        unit.querySelectorAll("input").forEach((input) => { input.disabled = !selected })
      })
    })
    this.submitTarget.value = `Receive ${total} ${total === 1 ? "unit" : "units"} into stock`
    this.submitTarget.disabled = total === 0
  }
}
