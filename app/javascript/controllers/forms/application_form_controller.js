import { Controller } from "@hotwired/stimulus"

/**
 * Application Form Controller (Simplified)
 * 
 * Basic form functionality that doesn't belong in specialized controllers.
 * Most functionality has been moved to:
 * - income-validation (FPL validation)
 * - currency-formatter (input formatting)  
 * - accessibility-announcer (screen reader support)
 */
export default class extends Controller {
  static targets = ["form"]

  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Application Form Controller connected")
    }
    // Store bound method reference for proper cleanup
    this._boundHandleFormSubmit = this.handleFormSubmit.bind(this)
    this.setupFormHandlers()
  }

  disconnect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Application Form Controller disconnected")
    }
    this.teardownFormHandlers()
  }

  setupFormHandlers() {
    // Basic form setup that doesn't belong elsewhere
    if (this.hasFormTarget) {
      this.formTarget.addEventListener("submit", this._boundHandleFormSubmit)
    }
  }

  teardownFormHandlers() {
    if (this.hasFormTarget) {
      this.formTarget.removeEventListener("submit", this._boundHandleFormSubmit)
    }
  }

  handleFormSubmit(event) {
    // Basic form submission handling
    if (process.env.NODE_ENV !== 'production') {
      console.log("Form submission started")
    }
    
    // Let other controllers handle their specific validation
    // This controller just handles basic form flow
  }

  // Legacy method for backward compatibility
  // New code should use the specialized controllers
  validateIncomeThreshold() {
    console.warn("validateIncomeThreshold is deprecated. Use income-validation controller instead.")
  }

  formatCurrencyInput() {
    console.warn("formatCurrencyInput is deprecated. Use currency-formatter controller instead.")
  }

  initiateDependentSubmission() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Form submission started");
    }
    this.submitForm();
  }
}
