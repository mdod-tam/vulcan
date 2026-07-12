import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["submitButton", "status"]
  // No defaults: every form using the status target must say what it means for that
  // specific form to be incomplete/ready, rather than inheriting generic wording from
  // whichever form happened to add this controller first.
  static values = {
    incompleteMessage: String,
    readyMessage: String
  }

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
      this._requiredControlsBlockSubmit() ||
      this._requiredRadioGroupBlocksSubmit() ||
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
        ? this.incompleteMessageValue
        : this.readyMessageValue
    }
  }

  _requiredControlsBlockSubmit() {
    return this._enabledVisibleFields(
      'input[required]:not([type="radio"]):not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="reset"]), select[required], textarea[required]'
    ).some((field) => this._fieldInvalid(field))
  }

  _requiredRadioGroupBlocksSubmit() {
    const radios = this._enabledVisibleFields('input[type="radio"][required]')
    const names = [...new Set(radios.map((radio) => radio.name).filter(Boolean))]

    return names.some((name) => {
      const group = radios.filter((radio) => radio.name === name)
      return group.length > 0 && !group.some((radio) => radio.checked)
    })
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

  _fieldInvalid(field) {
    if ((field.type || "").toLowerCase() === "file") {
      return field.required && (!field.files || field.files.length === 0)
    }

    if (typeof field.checkValidity === "function") {
      return !field.checkValidity()
    }

    return String(field.value || "").trim() === ""
  }

  elementIsVisible(element) {
    return !!(element.offsetParent || element.getClientRects().length)
  }
}
