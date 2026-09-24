import { Controller } from "@hotwired/stimulus"

class TotpFormController extends Controller {
  static targets = [
    "submitButton", 
    "codeInput",
    "mainContent"
  ]

  connect() {
    this.enableSubmitButton()

    // Store bound method reference for proper cleanup
    this._boundHandleStreamRender = this.handleStreamRender.bind(this)

    // Listen for stream renders targeting our container
    document.addEventListener("turbo:before-stream-render", this._boundHandleStreamRender)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this._boundHandleStreamRender)
  }

  // Called when the form submission starts via Turbo
  submitStart() {
    this.disableSubmitButton()
  }

  submitEnd() {
    this.enableSubmitButton()
  }

  // Called BEFORE a Turbo Stream action is processed
  handleStreamRender(event) {
    // Small delay to ensure DOM has updated after stream render
    setTimeout(() => {
      if (this.hasMainContentTarget) {
        const target = this.mainContentTarget
        const newForm = target.querySelector('[data-controller="totp-form"]')

        if (newForm && newForm !== this.element) {
          // Focus the code input in the new form
          const newCodeInput = newForm.querySelector('[data-totp-form-target="codeInput"]')
          if (newCodeInput) {
            newCodeInput.focus()
          }
        }
      }
    }, 100)
  }

  disableSubmitButton() {
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
    }
  }

  enableSubmitButton() {
    if (this.hasSubmitButtonTarget) {
      const button = this.submitButtonTarget
      button.disabled = false
    }
  }

  focusCodeInput() {
    if (this.hasCodeInputTarget) {
      const input = this.codeInputTarget
      input.focus()
    }
  }
}

export default TotpFormController
