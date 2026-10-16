import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["group", "groupCheckbox", "rowCheckbox", "quantity", "unitCount", "unitLabel"]
  static values = { existingUnits: Number }

  connect() {
    this.updateQuantities()
  }

  updateQuantities() {
    if (!this.hasUnitCountTarget) return
    const newUnits = this.quantityTargets.reduce((total, input) => total + Math.max(0, Number.parseInt(input.value, 10) || 0), 0)
    const units = newUnits + this.existingUnitsValue
    this.unitCountTarget.textContent = units
    if (this.hasUnitLabelTarget) this.unitLabelTarget.textContent = units === 1 ? "physical unit" : "physical units"
  }

  selectGroup(event) {
    const group = event.target.closest('[data-equipment-selection-target="group"]')
    group.querySelectorAll('[data-equipment-selection-target="rowCheckbox"]').forEach((checkbox) => {
      checkbox.checked = event.target.checked
    })
  }

  selectRow(event) {
    const group = event.target.closest('[data-equipment-selection-target="group"]')
    const rows = Array.from(group.querySelectorAll('[data-equipment-selection-target="rowCheckbox"]'))
    group.querySelector('[data-equipment-selection-target="groupCheckbox"]').checked = rows.every((checkbox) => checkbox.checked)
  }
}
