import { Controller } from "@hotwired/stimulus"

/**
 * Parses currency input, stores numeric values, and announces formatted amounts.
 */
export default class extends Controller {
  static targets = ["input"]
  
  static values = {
    locale: { type: String, default: "en-US" },
    currency: { type: String, default: "USD" },
    announceChanges: { type: Boolean, default: true }
  }

  connect() {
    // Listener removal needs the same bound functions.
    this._boundFormatCurrency = this.formatCurrency.bind(this)
    this._boundHandleInput = this.handleInput.bind(this)
    
    this.setupEventListeners()
  }

  disconnect() {
    this.teardownEventListeners()
  }

  setupEventListeners() {
    if (this.hasInputTarget) {
      this.inputTarget.addEventListener("blur", this._boundFormatCurrency)
      this.inputTarget.addEventListener("input", this._boundHandleInput)
    }
  }

  teardownEventListeners() {
    if (this.hasInputTarget) {
      this.inputTarget.removeEventListener("blur", this._boundFormatCurrency)
      this.inputTarget.removeEventListener("input", this._boundHandleInput)
    }
  }

  handleInput(event) {
    this.storeRawValue(event.target)
    
    // Income validation consumes the rawValueUpdated event.
    this.dispatch("rawValueUpdated", {
      detail: { 
        rawValue: this.extractRawValue(event.target.value),
        formattedValue: event.target.value
      }
    })
  }

  formatCurrency(event) {
    const input = event.target
    const value = input.value.trim()
    
    if (!value) return
    
    const numericValue = this.extractRawValue(value)
    
    if (!isNaN(numericValue) && numericValue >= 0) {
      this.storeRawValue(input, numericValue)
      this.announceFormattedValue(numericValue)
      
      this.dispatch("formatted", {
        detail: {
          rawValue: numericValue,
          formattedValue: this.formatValue(numericValue)
        }
      })
    }
  }

  extractRawValue(value) {
    const cleaned = value.toString().replace(/[^\d.-]/g, '')
    return parseFloat(cleaned) || 0
  }

  storeRawValue(input, value = null) {
    const numericValue = value !== null ? value : this.extractRawValue(input.value)
    input.dataset.rawValue = numericValue.toString()
  }

  formatValue(numericValue) {
    return numericValue.toLocaleString(this.localeValue, {
      style: 'currency',
      currency: this.currencyValue,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    })
  }

  announceFormattedValue(numericValue) {
    if (!this.announceChangesValue) return
    
    const formattedValue = this.formatValue(numericValue)
    this.announceToScreenReader(`Annual income: ${formattedValue}`)
  }

  announceToScreenReader(message) {
    this.dispatch("announce", {
      detail: { message },
      bubbles: true
    })
    
    // The currency live region is independent of accessibility-announcer.
    this.ensureAnnouncerExists()
    const announcer = this.getAnnouncer()
    if (announcer) {
      announcer.textContent = ''
      setTimeout(() => {
        announcer.textContent = message
      }, 100)
    }
  }

  ensureAnnouncerExists() {
    if (!this.getAnnouncer()) {
      this.createAnnouncer()
    }
  }

  createAnnouncer() {
    const announcer = document.createElement('div')
    announcer.id = 'currency-announcer'
    announcer.setAttribute('aria-live', 'polite')
    announcer.className = 'sr-only'
    document.body.appendChild(announcer)
  }

  getAnnouncer() {
    return document.getElementById('currency-announcer')
  }

  formatAction(event) {
    this.formatCurrency(event)
  }

  clearFormattingAction() {
    if (this.hasInputTarget) {
      const rawValue = this.inputTarget.dataset.rawValue
      if (rawValue) {
        this.inputTarget.value = rawValue
      }
    }
  }

  getRawValue() {
    if (!this.hasInputTarget) return 0
    
    const rawValue = this.inputTarget.dataset.rawValue
    if (rawValue) {
      return parseFloat(rawValue) || 0
    }
    
    return this.extractRawValue(this.inputTarget.value)
  }

  setRawValue(value) {
    if (!this.hasInputTarget) return
    
    const numericValue = parseFloat(value) || 0
    this.inputTarget.value = numericValue.toString()
    this.storeRawValue(this.inputTarget, numericValue)
  }
} 