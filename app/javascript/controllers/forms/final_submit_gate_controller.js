import { Controller } from "@hotwired/stimulus"
import { documentUploadBlocker } from "../../utils/document_upload_state"
import {
  blockingCheckboxGroups,
  blockingRadioGroups,
  blockingRequiredControls,
  elementIsVisible as isElementVisible,
  formatIncompleteMessage,
  incompleteGroupLabels
} from "../../utils/submit_gate_state"

export default class extends Controller {
  static targets = ["submitButton", "status"]

  connect() {
    this._incomeExceedsThreshold = false
    this._conditionalRequiredSourceValues = new Map()
    this._boundUpdate = this.update.bind(this)
    this._boundHandleIncomeValidation = this.handleIncomeValidation.bind(this)
    this.element.addEventListener("input", this._boundUpdate)
    this.element.addEventListener("change", this._boundUpdate)
    this.element.addEventListener("document-upload:status", this._boundUpdate)
    this.element.addEventListener("income-validation:validated", this._boundHandleIncomeValidation)
    this.update()
  }

  disconnect() {
    this.element.removeEventListener("input", this._boundUpdate)
    this.element.removeEventListener("change", this._boundUpdate)
    this.element.removeEventListener("document-upload:status", this._boundUpdate)
    this.element.removeEventListener("income-validation:validated", this._boundHandleIncomeValidation)
  }

  handleIncomeValidation(event) {
    this._incomeExceedsThreshold = !!event.detail.exceedsThreshold
    this.update()
  }

  update() {
    // Autosave keeps controls disabled during Turbo submission. Do not override that state while aria-busy is true.
    if (this.element.getAttribute("aria-busy") === "true") return
    this._syncConditionalRequiredControls()

    const hardBlockMessage = this._hardBlockMessage()
    const uploadBlocker = documentUploadBlocker(this.element, field => this.elementIsVisible(field))
    const disabled = hardBlockMessage !== null ||
      this._incomeExceedsThreshold ||
      this._requiredControlsBlockSubmit() ||
      this._requiredRadioGroupBlocksSubmit() ||
      this._checkboxGroupBlocksSubmit() ||
      uploadBlocker !== null

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
      const message = hardBlockMessage ?? uploadBlocker?.validationMessage ?? (disabled
          ? this._incompleteMessage()
          : this._readyMessage())
      if (this.statusTarget.textContent !== message) this.statusTarget.textContent = message
    }
  }

  // The server can block submission independently of form completeness, such as for pending identity review.
  // An empty attribute must not create a block.
  _hardBlockMessage() {
    const message = this.element.dataset.finalSubmitGateBlockedMessage
    return message ? message : null
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
        const restoreConditionalValues =
          this.element.dataset.finalSubmitGateRestoreConditionalValues === "true"

        if (!required) {
          field.value = ""
        } else if (hadPreviousValue && previousValue !== selectedValue) {
          field.value = restoreConditionalValues
            ? (field.dataset.finalSubmitGateRestoreValue || "")
            : ""
        }

        field.required = required
        field.setAttribute("aria-required", required ? "true" : "false")
        // Disable cleared controls so users cannot select a value that the next update discards.
        // Disabled controls do not block readiness or submit parameters, so no phone type survives this branch.
        field.disabled = !required
        this._conditionalRequiredSourceValues.set(key, selectedValue)
      })
  }

  // Forms can supply a detail template to name incomplete groups.
  // Without that template, preserve the base message so JavaScript does not bypass the portal view's localization.
  _incompleteMessage() {
    const base = this.element.dataset.finalSubmitGateIncompleteMessage ||
      "Complete all required confirmations before submitting."
    const template = this.element.dataset.finalSubmitGateIncompleteDetailMessage
    if (!template) return base

    return formatIncompleteMessage(
      base,
      template,
      incompleteGroupLabels(this.element, (element) => this.elementIsVisible(element))
    )
  }

  _readyMessage() {
    return this.element.dataset.finalSubmitGateReadyMessage ||
      "Application is ready to submit."
  }

  _blockingRequiredControls() {
    return blockingRequiredControls(this.element, (element) => this.elementIsVisible(element))
  }

  _blockingRadioGroups() {
    return blockingRadioGroups(this.element, (element) => this.elementIsVisible(element))
  }

  _blockingCheckboxGroups() {
    return blockingCheckboxGroups(this.element, (element) => this.elementIsVisible(element))
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

  elementIsVisible(element) {
    return isElementVisible(element)
  }
}
