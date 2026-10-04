import { Controller } from "@hotwired/stimulus"

/**
 * Shares a live region for form validation and currency announcements.
 */
export default class extends Controller {
  static values = {
    polite: { type: Boolean, default: true },
    delay: { type: Number, default: 100 }
  }

  connect() {
    this.ensureAnnouncerExists()
    
    // Listener removal needs the same bound functions.
    this._boundHandleIncomeValidation = this.handleIncomeValidation.bind(this)
    this._boundHandleCurrencyFormat = this.handleCurrencyFormat.bind(this)
    
    this.setupEventListeners()
  }

  disconnect() {
    this.teardownEventListeners()
    this.cleanupAnnouncers()
  }

  setupEventListeners() {
    this.element.addEventListener("income-validation:validated", this._boundHandleIncomeValidation)
    this.element.addEventListener("currency-formatter:formatted", this._boundHandleCurrencyFormat)
  }

  teardownEventListeners() {
    this.element.removeEventListener("income-validation:validated", this._boundHandleIncomeValidation)
    this.element.removeEventListener("currency-formatter:formatted", this._boundHandleCurrencyFormat)
  }

  ensureAnnouncerExists() {
    if (!this.getAnnouncer()) {
      this.createAnnouncer()
    }
  }

  createAnnouncer() {
    const announcer = document.createElement('div')
    announcer.id = 'accessibility-announcer'
    announcer.setAttribute('aria-live', this.politeValue ? 'polite' : 'assertive')
    announcer.setAttribute('aria-atomic', 'true')
    announcer.className = 'sr-only'
    document.body.appendChild(announcer)
  }

  getAnnouncer() {
    return document.getElementById('accessibility-announcer')
  }

  announce(message, options = {}) {
    if (!message) return
    
    const announcer = this.getAnnouncer()
    if (!announcer) return
    
    const urgency = options.urgency || (this.politeValue ? 'polite' : 'assertive')
    const delay = options.delay !== undefined ? options.delay : this.delayValue
    
    if (announcer.getAttribute('aria-live') !== urgency) {
      announcer.setAttribute('aria-live', urgency)
    }
    
    announcer.textContent = ''
    
    // The delay separates the empty and populated live-region states.
    setTimeout(() => {
      announcer.textContent = message
      
      // Remove the text only if it still matches this message.
      setTimeout(() => {
        if (announcer.textContent === message) {
          announcer.textContent = ''
        }
      }, 5000)
    }, delay)
  }

  handleIncomeValidation(event) {
    const { exceedsThreshold, threshold, householdSize } = event.detail
    
    if (exceedsThreshold) {
      const formattedThreshold = threshold.toLocaleString('en-US', {
        style: 'currency',
        currency: 'USD'
      })
      
      this.announce(
        `Warning: Your annual income exceeds the maximum threshold of ${formattedThreshold} for a household size of ${householdSize}. Applications with income above the threshold are not eligible for this program.`,
        { urgency: 'assertive' }
      )
    } else {
      this.announce('Income is within the eligible threshold.')
    }
  }

  handleCurrencyFormat(event) {
    const { formattedValue } = event.detail
    this.announce(`Annual income formatted as: ${formattedValue}`)
  }

  // Action methods for manual announcements
  announceAction(event) {
    const message = event.params?.message || event.target.dataset.message
    const urgency = event.params?.urgency || event.target.dataset.urgency
    
    if (message) {
      this.announce(message, { urgency })
    }
  }

  announceFormErrorsAction(event) {
    const form = event.target.closest('form')
    if (!form) return
    
    const errors = form.querySelectorAll('.field_with_errors, [aria-invalid="true"]')
    if (errors.length > 0) {
      const errorCount = errors.length
      const message = `Form has ${errorCount} ${errorCount === 1 ? 'error' : 'errors'}. Please review and correct the highlighted fields.`
      this.announce(message, { urgency: 'assertive' })
    }
  }

  announceSuccessAction(event) {
    const message = event.params?.message || 'Action completed successfully.'
    this.announce(message, { urgency: 'polite' })
  }

  // Announcements for form, page, modal, and loading states
  announceFieldValidation(fieldName, isValid, errorMessage = null) {
    if (isValid) {
      this.announce(`${fieldName} is valid.`)
    } else if (errorMessage) {
      this.announce(`${fieldName} error: ${errorMessage}`, { urgency: 'assertive' })
    }
  }

  announcePageChange(pageTitle) {
    this.announce(`Navigated to ${pageTitle}`, { delay: 500 })
  }

  announceModalOpen(modalTitle) {
    this.announce(`${modalTitle} dialog opened.`, { urgency: 'assertive' })
  }

  announceModalClose(modalTitle) {
    this.announce(`${modalTitle} dialog closed.`)
  }

  announceLoadingState(isLoading, context = 'content') {
    if (isLoading) {
      this.announce(`Loading ${context}...`, { urgency: 'polite' })
    } else {
      this.announce(`${context} loaded.`, { urgency: 'polite' })
    }
  }

  // Focus management for accessibility
  moveFocusToElement(selector) {
    const element = document.querySelector(selector)
    if (element) {
      element.focus()
      const elementName = element.getAttribute('aria-label') || 
                         element.getAttribute('title') || 
                         element.textContent?.trim() || 
                         'element'
      this.announce(`Focus moved to ${elementName}`)
    }
  }

  cleanupAnnouncers() {
    const announcer = this.getAnnouncer()
    if (announcer) {
      announcer.remove()
    }
  }

  static announceMessage(message, options = {}) {
    const announcer = document.getElementById('accessibility-announcer')
    if (announcer) {
      const delay = options.delay || 100
      announcer.textContent = ''
      setTimeout(() => {
        announcer.textContent = message
      }, delay)
    }
  }
} 