import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = ["group", "groupCheckbox", "row", "rowCheckbox", "quantity", "summary", "empty", "search", "model", "manufacturer", "category", "programGroup", "source", "contextField"]

  connect() {
    this.filter()
  }

  updateQuantities() {
    const selected = this.rowCheckboxTargets.filter(box => box.checked && !box.disabled)
    let units = 0
    this.rowTargets.forEach(row => {
      const checkbox = row.querySelector('[data-equipment-selection-target="rowCheckbox"]')
      if (!checkbox) return
      const input = row.querySelector('[data-equipment-selection-target="quantity"]')
      if (input) {
        if (!input.dataset.maximum) input.dataset.maximum = input.max
        input.disabled = checkbox.disabled
        input.required = checkbox.checked && !checkbox.disabled
        input.min = input.required ? "1" : ""
        input.max = input.required ? input.dataset.maximum : ""
      }
      const stockCoverage = row.querySelector("[data-stock-coverage]")
      if (stockCoverage) {
        const quantity = checkbox.disabled ? Number(row.dataset.requestedQuantity) : input ? Number(input.value) : 1
        const available = Number(row.dataset.availableStock)
        const label = Number.isInteger(quantity) && quantity > 0 ?
          (available === 0 ? "No" : available >= quantity ? "All" : "Partial") : "—"
        if (stockCoverage.textContent !== label) stockCoverage.textContent = label
      }
      if (checkbox.checked && !checkbox.disabled) units += input ? Math.max(0, Number.parseInt(input.value, 10) || 0) : 1
    })
    if (this.hasSummaryTarget) {
      const hidden = selected.filter(box => box.closest('[data-equipment-selection-target="row"]').hidden).length
      this.summaryTarget.textContent = `${selected.length} selected (${hidden} hidden by filters) · ${units} ${units === 1 ? "unit" : "units"}`
    }
    this.groupTargets.forEach(group => {
      const boxes = Array.from(group.querySelectorAll('[data-equipment-selection-target="rowCheckbox"]'))
        .filter(box => !box.disabled && !box.closest('[data-equipment-selection-target="row"]').hidden)
      const toggle = group.querySelector('[data-equipment-selection-target="groupCheckbox"]')
      if (!toggle) return
      toggle.disabled = boxes.length === 0
      toggle.checked = boxes.length > 0 && boxes.every(box => box.checked)
      toggle.indeterminate = boxes.some(box => box.checked) && !toggle.checked
    })
  }

  selectGroup(event) {
    const group = event.target.closest('[data-equipment-selection-target="group"]')
    Array.from(group.querySelectorAll('[data-equipment-selection-target="row"]'))
      .filter(row => !row.hidden).forEach(row => this.setSelected(row, event.target.checked))
    this.updateQuantities()
  }

  selectMatching() {
    this.rowTargets.filter(row => !row.hidden).forEach(row => this.setSelected(row, true))
    this.updateQuantities()
  }

  setSelected(row, checked) {
    const checkbox = row.querySelector('[data-equipment-selection-target="rowCheckbox"]')
    if (!checkbox || checkbox.disabled) return
    checkbox.checked = checked
    const input = row.querySelector('[data-equipment-selection-target="quantity"]')
    if (checked && input) {
      const maximum = Number(input.dataset.maximum)
      const quantity = Number(input.value)
      if (!Number.isInteger(quantity) || quantity <= 0 || quantity > maximum) input.value = String(maximum)
    }
  }

  selectRow(event) {
    if (event && !event.target.checked) {
      const input = event.target.closest('[data-equipment-selection-target="row"]').querySelector('[data-equipment-selection-target="quantity"]')
      if (input?.validity.badInput) input.value = ""
    }
    this.updateQuantities()
  }

  quantityChanged(event) {
    const checkbox = event.target.closest('[data-equipment-selection-target="row"]').querySelector('input[type="checkbox"]')
    if (checkbox.disabled) return
    if (Number(event.target.value) > 0) checkbox.checked = true
    if (!checkbox.checked && event.target.validity.badInput) event.target.value = ""
    this.updateQuantities()
  }

  applyFilters(event) {
    event.preventDefault()
    this.filter()
  }

  filter() {
    const query = this.hasSearchTarget ? this.searchTarget.value.toLocaleLowerCase().trim() : ""
    this.rowTargets.forEach(row => {
      row.hidden = (query && !row.dataset.searchText.toLocaleLowerCase().includes(query)) ||
        (this.hasModelTarget && this.modelTarget.value && row.dataset.model !== this.modelTarget.value) ||
        (this.hasManufacturerTarget && this.manufacturerTarget.value && row.dataset.manufacturer !== this.manufacturerTarget.value) ||
        (this.hasCategoryTarget && this.categoryTarget.value && row.dataset.category !== this.categoryTarget.value) ||
        (this.hasProgramGroupTarget && this.programGroupTarget.value && !row.dataset.programGroups.split(",").includes(this.programGroupTarget.value)) ||
        (this.hasSourceTarget && this.sourceTarget.value && row.dataset.source !== this.sourceTarget.value)
      setVisible(row, !row.hidden, { inlineStyleFallback: false })
    })
    this.groupTargets.forEach(group => {
      const rows = Array.from(group.querySelectorAll('[data-equipment-selection-target="row"]'))
      group.hidden = rows.length > 0 && rows.every(row => row.hidden)
    })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.rowTargets.some(row => !row.hidden)
    const filters = this.element.querySelector('#equipment-filters')
    this.contextFieldTargets.forEach(field => {
      const control = filters?.elements.namedItem(field.name)
      if (control) field.value = control.value
    })
    this.updateQuantities()
  }
}
