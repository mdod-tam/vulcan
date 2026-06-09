import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["submitButton", "status"]

  connect() {
    this._incomeExceedsThreshold = false
    this._boundUpdate = this.update.bind(this)
    this._boundHandleIncomeValidation = this.handleIncomeValidation.bind(this)
    this.element.addEventListener("input", this._boundUpdate)
    this.element.addEventListener("change", this._boundUpdate)
    this.element.addEventListener("income-validation:validated", this._boundHandleIncomeValidation)
    this.update()
  }

  disconnect() {
    this.element.removeEventListener("input", this._boundUpdate)
    this.element.removeEventListener("change", this._boundUpdate)
    this.element.removeEventListener("income-validation:validated", this._boundHandleIncomeValidation)
  }

  handleIncomeValidation(event) {
    this._incomeExceedsThreshold = !!event.detail.exceedsThreshold
    this.update()
  }

  update() {
    const disabled = this._incomeExceedsThreshold ||
      this._requiredCheckboxBlocksSubmit() ||
      this._requiredNonFileFieldsBlockSubmit() ||
      this._checkboxGroupBlocksSubmit()

    this.submitButtonTargets.forEach((button) => {
      button.disabled = disabled
      button.setAttribute("aria-disabled", disabled ? "true" : "false")
      if (disabled) {
        button.setAttribute("disabled", "disabled")
      } else {
        button.removeAttribute("disabled")
      }
    })

    if (this.hasStatusTarget) {
      this.statusTarget.textContent = disabled
        ? "Complete all required confirmations before submitting."
        : "Application is ready to submit."
    }
  }

  _requiredCheckboxBlocksSubmit() {
    return this._enabledVisibleFields('input[type="checkbox"][required]')
      .some((field) => !field.checked)
  }

  _requiredNonFileFieldsBlockSubmit() {
    return this._enabledVisibleFields(
      'input[required]:not([type="checkbox"]):not([type="radio"]):not([type="file"]):not([type="hidden"]), select[required], textarea[required]'
    ).some((field) => field.value.trim() === "")
  }

  _checkboxGroupBlocksSubmit() {
    return Array.from(this.element.querySelectorAll("[data-requires-one-checkbox]"))
      .filter((group) => this.elementIsVisible(group))
      .some((group) => {
        const checkboxes = Array.from(group.querySelectorAll('input[type="checkbox"]'))
          .filter((field) => !field.disabled && this.elementIsVisible(field))
        return checkboxes.length > 0 && !checkboxes.some((field) => field.checked)
      })
  }

  _enabledVisibleFields(selector) {
    return Array.from(this.element.querySelectorAll(selector))
      .filter((field) => !field.disabled && this.elementIsVisible(field))
  }

  elementIsVisible(element) {
    return !!(element.offsetParent || element.getClientRects().length)
  }
}
