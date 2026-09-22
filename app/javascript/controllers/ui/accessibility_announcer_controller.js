import { Controller } from "@hotwired/stimulus"

/**
 * Accessibility Announcer Controller
 * 
 * Provides centralized screen reader announcements and accessibility features
 * for dynamic content updates in forms and applications.
 */
export default class extends Controller {
  static values = {
    polite: { type: Boolean, default: true },
    delay: { type: Number, default: 100 }
  }

  connect() {
    this.ensureAnnouncerExists()
    
    // Store bound method references for proper cleanup
    this._boundHandleIncomeValidation = this.handleIncomeValidation.bind(this)
    this._boundHandleCurrencyFormat = this.handleCurrencyFormat.bind(this)
    
    this.setupEventListeners()
  }

  disconnect() {
    this.teardownEventListeners()
    this.cleanupAnnouncers()
  }

  setupEventListeners() {
    // Listen for custom events from other controllers
    this.element.addEventListener("income-validation:validated", this._boundHandleIncomeValidation)
    this.element.addEventListener("currency-formatter:formatted", this._boundHandleCurrencyFormat)
  }

  teardownEventListeners() {
    this.element.removeEventListener("income-validation:validated", this._boundHandleIncomeValidation)
    this.element.removeEventListener("currency-formatter:formatted", this._boundHandleCurrencyFormat)
  }

  // Create or ensure the main announcer element exists
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

  // Main announcement method
  announce(message, options = {}) {
    if (!message) return
    
    const announcer = this.getAnnouncer()
    if (!announcer) return
    
    const urgency = options.urgency || (this.politeValue ? 'polite' : 'assertive')
    const delay = options.delay !== undefined ? options.delay : this.delayValue
    
    // Update aria-live if different urgency is requested
    if (announcer.getAttribute('aria-live') !== urgency) {
      announcer.setAttribute('aria-live', urgency)
    }
    
    // Clear existing content first
    announcer.textContent = ''
    
    // Set new content after delay to ensure screen readers pick it up
    setTimeout(() => {
      announcer.textContent = message
      
      // Auto-clear after 5 seconds to prevent stale announcements
      setTimeout(() => {
        if (announcer.textContent === message) {
          announcer.textContent = ''
        }
      }, 5000)
    }, delay)
  }

  // Handle income validation announcements
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

  // Handle currency formatting announcements  
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

  // Utility methods for form interactions
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

  // Clean up method
  cleanupAnnouncers() {
    const announcer = this.getAnnouncer()
    if (announcer) {
      announcer.remove()
    }
  }

  // Public API for other controllers
  static announceMessage(message, options = {}) {
    // Static method for quick announcements without controller instance
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