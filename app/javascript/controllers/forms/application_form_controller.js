import { Controller } from "@hotwired/stimulus"

/**
 * Listens for submit on the application form target. Income validation, currency formatting, and
 * screen reader announcements belong to the income-validation, currency-formatter, and
 * accessibility-announcer controllers.
 */
export default class extends Controller {
  static targets = ["form"]

  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Application Form Controller connected")
    }
    // Listener removal needs the same bound function.
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
    if (process.env.NODE_ENV !== 'production') {
      console.log("Form submission started")
    }
  }
}
