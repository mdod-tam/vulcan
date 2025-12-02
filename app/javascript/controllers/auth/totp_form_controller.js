import { Controller } from "@hotwired/stimulus"

class TotpFormController extends Controller {
  static targets = [
    "submitButton", 
    "codeInput",
    "mainContent"
  ]

  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("TOTP Form controller connected")
    }
    this.enableSubmitButton()
    
    // Store bound method reference for proper cleanup
    this._boundHandleStreamRender = this.handleStreamRender.bind(this)
    
    // Listen for stream renders targeting our container
    document.addEventListener("turbo:before-stream-render", this._boundHandleStreamRender)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this._boundHandleStreamRender)
    if (process.env.NODE_ENV !== 'production') {
      console.log("TOTP Form controller disconnected")
    }
  }

  // Called when the form submission starts via Turbo
  submitStart() {
    this.disableSubmitButton()
    if (process.env.NODE_ENV !== 'production') {
      console.log("Form submitted, button disabled")
    }
  }

  // Called BEFORE a Turbo Stream action is processed
  handleStreamRender(event) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Turbo stream render event:", event)
    }
    
    // Small delay to ensure DOM has updated after stream render
    setTimeout(() => {
      // Use target safety mixin for safe access
      if (this.hasMainContentTarget) {
        const target = this.mainContentTarget
        const newForm = target.querySelector('[data-controller="totp-form"]')
        
        if (newForm && newForm !== this.element) {
          if (process.env.NODE_ENV !== 'production') {
            console.log("New TOTP form detected after stream render, focusing code input")
          }
          
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
      if (process.env.NODE_ENV !== 'production') {
        console.log("Submit button enabled")
      }
    }
  }
  
  focusCodeInput() {
    if (this.hasCodeInputTarget) {
      const input = this.codeInputTarget
      input.focus()
      if (process.env.NODE_ENV !== 'production') {
        console.log("Code input field focused")
      }
    }
  }
}

// Apply target safety mixin

export default TotpFormController
