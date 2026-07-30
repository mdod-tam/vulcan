import { Controller } from "@hotwired/stimulus"

const REQUIRED_CONTROL_SELECTOR =
  'input[required]:not([type="radio"]):not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="reset"]), select[required], textarea[required]'

export default class extends Controller {
  static targets = ["submitButton", "status"]

  connect() {
    this._incomeExceedsThreshold = false
    this._conditionalRequiredSourceValues = new Map()
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
    this._syncConditionalRequiredControls()

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
        ? this._incompleteMessage()
        : this._readyMessage()
    }
  }

  _syncConditionalRequiredControls() {
    const sources = Array.from(
      this.element.querySelectorAll("[data-final-submit-gate-conditional-required-source]")
    )

    Array.from(this.element.querySelectorAll("[data-final-submit-gate-conditional-required]"))
      .forEach((field) => {
        const key = field.dataset.finalSubmitGateConditionalRequired
        const selectedSource = sources.find((source) => {
          return source.checked && source.dataset.finalSubmitGateConditionalRequiredSource === key
        })
        const selectedValue = selectedSource ? `${selectedSource.name}:${selectedSource.value}` : null
        const hadPreviousValue = this._conditionalRequiredSourceValues.has(key)
        const previousValue = this._conditionalRequiredSourceValues.get(key)
        const required = selectedSource?.dataset.finalSubmitGateRequiredWhenSelected === "true"

        if (!required || (hadPreviousValue && previousValue !== selectedValue)) {
          field.value = ""
        }

        field.required = required
        field.setAttribute("aria-required", required ? "true" : "false")
        // A control whose value is cleared on every update must not stay operable: leaving it
        // enabled invites a selection that is silently discarded. Disabling also keeps it out of
        // _enabledVisibleFields, so the gate never waits on a field it just blanked, and out of
        // the submitted params, which is the intended "no phone type survives" outcome.
        field.disabled = !required
        this._conditionalRequiredSourceValues.set(key, selectedValue)
      })
  }

  // "Complete every required decision" does not say which decision is missing. When a form opts
  // in by setting a detail template, name the incomplete groups. Forms that do not set it keep
  // the previous message verbatim -- this controller is shared with the constituent portal,
  // where an English string composed in JavaScript would bypass the view's own localization.
  _incompleteMessage() {
    const base = this.element.dataset.finalSubmitGateIncompleteMessage ||
      "Complete all required confirmations before submitting."
    const template = this.element.dataset.finalSubmitGateIncompleteDetailMessage
    if (!template) return base

    const labels = this._incompleteGroupLabels()
    if (labels.length === 0) return base

    return `${base} ${template.replace("%{items}", labels.join(", "))}`
  }

  _readyMessage() {
    return this.element.dataset.finalSubmitGateReadyMessage ||
      "Application is ready to submit."
  }

  _incompleteGroupLabels() {
    const labels = [
      ...this._blockingRequiredControls(),
      ...this._blockingRadioGroups().map((group) => group[0]),
      ...this._blockingCheckboxGroups()
    ].map((element) => this._groupLabelFor(element))

    return [...new Set(labels.filter(Boolean))]
  }

  // Grouped inputs are named by their enclosing fieldset's legend -- an individual radio's own
  // label identifies one option ("Subject #5: ..."), not the decision. Single controls are named
  // by their own label, which is more specific than the surrounding group.
  _groupLabelFor(element) {
    if (!element) return null

    const type = (element.type || "").toLowerCase()
    const ownLabel = element.labels?.[0]?.textContent?.trim()

    if (type !== "radio" && type !== "checkbox" && ownLabel) return ownLabel

    const legend = element.closest("fieldset")?.querySelector(":scope > legend")?.textContent?.trim()

    return legend || ownLabel || element.getAttribute("aria-label") || element.name || null
  }

  _blockingRequiredControls() {
    return this._enabledVisibleFields(REQUIRED_CONTROL_SELECTOR).filter((field) => this._fieldInvalid(field))
  }

  _blockingRadioGroups() {
    const radios = this._enabledVisibleFields('input[type="radio"][required]')
    const names = [...new Set(radios.map((radio) => radio.name).filter(Boolean))]

    return names
      .map((name) => radios.filter((radio) => radio.name === name))
      .filter((group) => group.length > 0 && !group.some((radio) => radio.checked))
  }

  _blockingCheckboxGroups() {
    return Array.from(this.element.querySelectorAll("[data-requires-one-checkbox]"))
      .filter((group) => this.elementIsVisible(group))
      .filter((group) => {
        const checkboxes = Array.from(group.querySelectorAll('input[type="checkbox"]'))
          .filter((field) => !field.disabled && this.elementIsVisible(field))
        return checkboxes.length > 0 && !checkboxes.some((field) => field.checked)
      })
  }

  _requiredControlsBlockSubmit() {
    return this._blockingRequiredControls().length > 0
  }

  _requiredRadioGroupBlocksSubmit() {
    return this._blockingRadioGroups().length > 0
  }

  _checkboxGroupBlocksSubmit() {
    return this._blockingCheckboxGroups().length > 0
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
