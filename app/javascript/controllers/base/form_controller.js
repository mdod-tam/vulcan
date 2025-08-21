import { Controller } from "@hotwired/stimulus"
import { railsRequest } from "../../services/rails_request"
import { setVisible } from "../../utils/visibility"

/**
 * Base controller for forms with common functionality:
 * - Submission handling with loading states
 * - Error display
 * - Field validation
 * - Status messages
 */
export default class BaseFormController extends Controller {
  static targets = [
    "form",
    "submitButton", 
    "statusMessage",
    "errorContainer",
    "fieldError"
  ]



  static values = {
    url: String,
    method: { type: String, default: "post" },
    resetOnSuccess: { type: Boolean, default: false },
    redirectOnSuccess: { type: Boolean, default: true }
  }

  connect() {
    this.requestKey = `form-${this.identifier}-${Date.now()}`
    this._setupFormHandlers()
  }

  disconnect() {
    railsRequest.cancel(this.requestKey)
    this._teardownFormHandlers()
  }

  /**
   * Submit the form with standard handling
   */
  async submit(event) {
    if (event) {
      event.preventDefault()
    }

    // Clear previous errors
    this.clearErrors()
    
    // Show loading state
    this.setLoadingState(true)

    try {
      const formData = this.collectFormData()
      
      // Allow subclasses to validate
      const validationResult = await this.validateBeforeSubmit(formData)
      if (!validationResult.valid) {
        this.handleValidationErrors(validationResult.errors)
        return
      }

      // Perform request
      const result = await railsRequest.perform({
        method: this.methodValue,
        url: this.urlValue || this.formTarget.action,
        body: formData,
        key: this.requestKey
      })

      if (result.success) {
        await this.handleSuccess(result.data)
      } else if (!result.aborted) {
        this.handleError(new Error('Request failed'))
      }

    } catch (error) {
      this.handleError(error)
    } finally {
      this.setLoadingState(false)
    }
  }

  /**
   * Collect form data - can be overridden for custom handling
   */
  collectFormData() {
    if (!this.hasFormTarget) {
      return {}
    }

    const formData = new FormData(this.formTarget)
    const data = {}
    
    for (const [key, value] of formData.entries()) {
      // Handle array fields
      if (key.endsWith('[]')) {
        const arrayKey = key.slice(0, -2)
        data[arrayKey] = data[arrayKey] || []
        data[arrayKey].push(value)
      } else {
        data[key] = value
      }
    }

    return data
  }

  /**
   * Override in subclasses for custom validation
   */
  async validateBeforeSubmit(data) {
    return { valid: true }
  }

  /**
   * Handle successful submission
   */
  async handleSuccess(data) {
    // Show success message locally
    if (data.message) {
      this.showStatus(data.message, 'success')
    }

    // Reset form if configured
    if (this.resetOnSuccessValue && this.hasFormTarget) {
      this.formTarget.reset()
    }

    // Dispatch success event
    this.dispatch('success', { detail: data })

    // Handle redirect if present
    if (this.redirectOnSuccessValue && data.redirect_url) {
      window.location.href = data.redirect_url
    }
  }

  /**
   * Handle submission errors
   */
  handleError(error) {
    console.error('Form submission error:', error)

    if (error.data?.errors) {
      this.handleValidationErrors(error.data.errors)
    } else {
      this.showStatus(error.message || 'An error occurred', 'error')
    }

    this.dispatch('error', { detail: error })
  }

  /**
   * Handle validation errors
   */
  handleValidationErrors(errors) {
    // Display field-specific errors
    Object.entries(errors).forEach(([field, messages]) => {
      this.showFieldError(field, Array.isArray(messages) ? messages.join(', ') : messages)
    })

    // Show general error message
    this.showStatus('Please correct the errors below', 'error')
  }

  /**
   * Show field-specific error
   */
  showFieldError(fieldName, message) {
    // Find field
    const field = this.formTarget?.querySelector(`[name=\"${fieldName}\"], [name=\"${fieldName}[]\"]`)
    if (!field) return

    // Look for existing server-rendered error element
    const errorElement = field.parentElement.querySelector(`[data-field-error=\"${fieldName}\"]`)
    if (errorElement) {
      errorElement.textContent = message
      setVisible(errorElement, true)
    }

    // Add error styling to field
    field.classList.add('border-red-500')
  }

  /**
   * Clear all errors
   */
  clearErrors() {
    // Clear field errors
    this.element.querySelectorAll('.field-error-message').forEach(el => {
      el.textContent = ''
      setVisible(el, false)
    })

    // Remove error styling
    this.element.querySelectorAll('.border-red-500').forEach(el => {
      el.classList.remove('border-red-500')
    })

    // Clear error container
    if (this.hasErrorContainerTarget) {
      this.errorContainerTarget.innerHTML = ''
      setVisible(this.errorContainerTarget, false)
    }
  }

  /**
   * Show status message
   */
  showStatus(message, type = 'info') {
    if (!this.hasStatusMessageTarget) return

    this.statusMessageTarget.textContent = message
    
    // Reset classes
    this.statusMessageTarget.className = 'text-sm mt-2'
    
    // Add type-specific classes
    const classes = {
      success: 'text-green-600',
      error: 'text-red-600',
      info: 'text-blue-600'
    }
    
    this.statusMessageTarget.classList.add(classes[type] || classes.info)
    setVisible(this.statusMessageTarget, true)

    // Auto-hide success messages
    if (type === 'success') {
      setTimeout(() => {
        setVisible(this.statusMessageTarget, false)
      }, 3000)
    }
  }

  /**
   * Set loading state
   */
  setLoadingState(loading) {
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = loading
      
      if (loading) {
        this._originalButtonText = this.submitButtonTarget.innerHTML
        this.submitButtonTarget.innerHTML = this.loadingButtonHTML()
      } else if (this._originalButtonText) {
        this.submitButtonTarget.innerHTML = this._originalButtonText
      }
    }

    // Disable form inputs during submission
    if (this.hasFormTarget) {
      const inputs = this.formTarget.querySelectorAll('input, select, textarea, button')
      inputs.forEach(input => {
        if (input !== this.submitButtonTarget) {
          input.disabled = loading
        }
      })
    }
  }

  /**
   * Get loading button HTML - can be overridden
   */
  loadingButtonHTML() {
    return '<span class="spinner inline-block w-4 h-4 border-2 border-current border-t-transparent rounded-full animate-spin mr-2"></span> Saving...'
  }

  /**
   * Set up form event handlers
   */
  _setupFormHandlers() {
    if (this.hasFormTarget) {
      this._boundSubmit = this.submit.bind(this)
      this._boundClearFieldError = this.clearFieldError.bind(this)
      
      this.formTarget.addEventListener('submit', this._boundSubmit)
      
      // Clear field errors on input
      this.formTarget.addEventListener('input', this._boundClearFieldError)
      this.formTarget.addEventListener('change', this._boundClearFieldError)
    }
  }

  /**
   * Clean up event handlers
   */
  _teardownFormHandlers() {
    if (this.hasFormTarget && this._boundSubmit) {
      this.formTarget.removeEventListener('submit', this._boundSubmit)
      this.formTarget.removeEventListener('input', this._boundClearFieldError)
      this.formTarget.removeEventListener('change', this._boundClearFieldError)
    }
  }

  /**
   * Clear error for a specific field
   */
  clearFieldError(event) {
    const field = event.target
    field.classList.remove('border-red-500')
    
    const errorElement = field.parentElement.querySelector(`[data-field-error="${field.name}"]`)
    if (errorElement) {
      errorElement.textContent = ''
      setVisible(errorElement, false)
    }
  }

  // ============================================================================
  // COMMON VALIDATION METHODS
  // ============================================================================

  /**
   * Validate email format
   * @param {string} email - Email address to validate
   * @returns {boolean} - Whether email is valid
   */
  validateEmail(email) {
    if (!email || typeof email !== 'string') return false
    return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())
  }

  /**
   * Validate phone number (US format)
   * @param {string} phone - Phone number to validate
   * @returns {boolean} - Whether phone is valid
   */
  validatePhone(phone) {
    if (!phone || typeof phone !== 'string') return false
    const cleaned = phone.replace(/\D/g, '')
    return cleaned.length === 10
  }

  /**
   * Validate required field
   * @param {any} value - Value to validate
   * @returns {boolean} - Whether value is present
   */
  validateRequired(value) {
    if (value === null || value === undefined) return false
    if (typeof value === 'string') return value.trim().length > 0
    if (Array.isArray(value)) return value.length > 0
    return true
  }

  /**
   * Validate minimum length
   * @param {string} value - String to validate
   * @param {number} minLength - Minimum required length
   * @returns {boolean} - Whether string meets minimum length
   */
  validateMinLength(value, minLength) {
    if (!value || typeof value !== 'string') return false
    return value.trim().length >= minLength
  }

  /**
   * Validate maximum length
   * @param {string} value - String to validate
   * @param {number} maxLength - Maximum allowed length
   * @returns {boolean} - Whether string is under maximum length
   */
  validateMaxLength(value, maxLength) {
    if (!value || typeof value !== 'string') return true
    return value.length <= maxLength
  }

  /**
   * Validate numeric range
   * @param {string|number} value - Value to validate
   * @param {number} min - Minimum value
   * @param {number} max - Maximum value
   * @returns {boolean} - Whether value is in range
   */
  validateRange(value, min, max) {
    const num = parseFloat(value)
    if (isNaN(num)) return false
    return num >= min && num <= max
  }

  /**
   * Validate date format (MM/DD/YYYY)
   * @param {string} dateString - Date string to validate
   * @returns {boolean} - Whether date is valid
   */
  validateDate(dateString) {
    if (!dateString || typeof dateString !== 'string') return false
    
    const dateRegex = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/
    const match = dateString.match(dateRegex)
    
    if (!match) return false
    
    const [, month, day, year] = match
    const date = new Date(year, month - 1, day)
    
    return date.getFullYear() == year &&
           date.getMonth() == month - 1 &&
           date.getDate() == day
  }

  /**
   * Validate multiple fields with rules
   * @param {Object} data - Form data object
   * @param {Object} rules - Validation rules object
   * @returns {Object} - Validation result with errors
   */
  validateFields(data, rules) {
    const errors = {}
    
    Object.entries(rules).forEach(([field, fieldRules]) => {
      const value = data[field]
      const fieldErrors = []
      
      fieldRules.forEach(rule => {
        if (rule.required && !this.validateRequired(value)) {
          fieldErrors.push(rule.message || `${field} is required`)
        }
        
        if (rule.email && value && !this.validateEmail(value)) {
          fieldErrors.push(rule.message || `${field} must be a valid email`)
        }
        
        if (rule.phone && value && !this.validatePhone(value)) {
          fieldErrors.push(rule.message || `${field} must be a valid phone number`)
        }
        
        if (rule.minLength && value && !this.validateMinLength(value, rule.minLength)) {
          fieldErrors.push(rule.message || `${field} must be at least ${rule.minLength} characters`)
        }
        
        if (rule.maxLength && value && !this.validateMaxLength(value, rule.maxLength)) {
          fieldErrors.push(rule.message || `${field} must be no more than ${rule.maxLength} characters`)
        }
        
        if (rule.range && value && !this.validateRange(value, rule.range.min, rule.range.max)) {
          fieldErrors.push(rule.message || `${field} must be between ${rule.range.min} and ${rule.range.max}`)
        }
        
        if (rule.custom && typeof rule.custom === 'function' && !rule.custom(value)) {
          fieldErrors.push(rule.message || `${field} is invalid`)
        }
      })
      
      if (fieldErrors.length > 0) {
        errors[field] = fieldErrors
      }
    })
    
    return {
      valid: Object.keys(errors).length === 0,
      errors
    }
  }
}
