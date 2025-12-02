import { Controller } from "@hotwired/stimulus"
import { railsRequest } from "../../services/rails_request"
import { createFormChangeDebounce } from "../../utils/debounce"
import { setVisible } from "../../utils/visibility"

class AutosaveController extends Controller {
  static targets = ["form", "autosaveStatus", "fieldError"]

  static values = {
    url: String,
    debounceWait: { type: Number, default: 1000 },
    editFormUrl: String,
    editAutosaveUrl: String
  }

  connect() {
    // Use our tested debounce utility
    this.debouncedSave = createFormChangeDebounce(() => this.executeFieldSave())

    // Request key for tracking
    this.requestKey = `autosave-${this.identifier}-${Date.now()}`

    this.setupFieldListeners()
  }

  disconnect() {
    // Cancel any pending autosave requests
    railsRequest.cancel(this.requestKey)

    // Clean up event listeners
    this.cleanupEventListeners()

    // Clear timers
    if (this._statusTimeout) {
      clearTimeout(this._statusTimeout)
      this._statusTimeout = null
    }
  }

  setupFieldListeners() {
    if (!this.hasFormTarget) return

    // Get all form inputs except file inputs, buttons, and submit inputs
    const formInputs = this.formTarget.querySelectorAll(
      'input:not([type="file"]):not([type="button"]):not([type="submit"]), select, textarea'
    )

    // Store bound handler for cleanup
    this._boundHandleBlur = this.handleBlur.bind(this)
    this._fieldElements = []

    formInputs.forEach(input => {
      // Store reference for cleanup
      this._fieldElements.push(input)
      // Add blur event listener to trigger autosave
      input.addEventListener('blur', this._boundHandleBlur)
    })
  }

  cleanupEventListeners() {
    if (this._fieldElements && this._boundHandleBlur) {
      this._fieldElements.forEach(element => {
        element.removeEventListener('blur', this._boundHandleBlur)
      })
    }
    this._fieldElements = []
    this._boundHandleBlur = null
  }

  handleBlur(event) {
    // Store the element for the debounced save
    this._pendingElement = event.target
    // Trigger debounced save
    this.debouncedSave()
  }

  executeFieldSave() {
    // Execute the actual save with the stored element
    if (this._pendingElement) {
      this.saveField(this._pendingElement)
      this._pendingElement = null
    }
  }

  async saveField(element) {
    // Skip if no element, it's a file input, or has the 'data-no-autosave' attribute
    if (!element || element.type === 'file' || element.dataset.noAutosave) return

    // Get field name and value
    const fieldName = element.name
    let fieldValue = element.value

    // Special handling for checkboxes
    if (element.type === 'checkbox') {
      fieldValue = element.checked
    }

    // Do not save if the field name is empty
    if (!fieldName) return

    // Show saving status
    this.updateStatus("Saving...", "text-indigo-600")

    try {
      // Clear any existing errors for this field
      this.clearFieldErrorNear(element)

      // Use centralized rails request service
      const result = await railsRequest.perform({
        method: 'patch',
        url: this.urlValue,
        body: {
          field_name: fieldName,
          field_value: fieldValue
        },
        key: this.requestKey
      })

      if (result.success) {
        const data = result.data

        if (data.success) {
          this.updateStatus("Saved", "text-green-600")

          // If this is a new application, update the form action URL 
          // to include the new application ID
          if (data.applicationId && !this.formTarget.action.includes(`/${data.applicationId}`) && this.hasEditFormUrlValue && this.hasEditAutosaveUrlValue) {
            // Use Rails-generated URLs
            const newFormAction = this.editFormUrlValue.replace(':id', data.applicationId)
            this.formTarget.action = newFormAction

            // Update the autosave URL as well
            this.urlValue = this.editAutosaveUrlValue.replace(':id', data.applicationId)

            // Add or update the _method hidden field to PATCH
            let methodField = this.formTarget.querySelector('input[name="_method"]')
            if (!methodField) {
              methodField = document.createElement('input')
              methodField.type = 'hidden'
              methodField.name = '_method'
              this.formTarget.appendChild(methodField)
            }
            methodField.value = 'patch'
          }
        } else {
          this.updateStatus("Error saving", "text-red-600")

          // Display field-specific errors
          if (data.errors) {
            Object.entries(data.errors).forEach(([field, messages]) => {
              if (field === fieldName) {
                this.displayFieldError(element, messages.join(', '))
              }
            })
          }
        }
      } else if (!result.aborted) {
        this.updateStatus("Failed to save", "text-red-600")
      }

    } catch (error) {
      if (error.name !== "AbortError") {
        console.error('Autosave error:', error)
        this.updateStatus("Failed to save", "text-red-600")

        // Handle error data if available
        if (error.data?.errors) {
          Object.entries(error.data.errors).forEach(([field, messages]) => {
            if (field === fieldName) {
              this.displayFieldError(element, messages.join(', '))
            }
          })
        }
      }
    }

    // Clear any existing status timeout to prevent stacking
    if (this._statusTimeout) {
      clearTimeout(this._statusTimeout)
    }

    // Clear status message after a delay
    this._statusTimeout = setTimeout(() => {
      this.updateStatus("", "")
      this._statusTimeout = null
    }, 3000)
  }

  updateStatus(message, cssClass) {
    if (this.hasAutosaveStatusTarget) {
      const target = this.autosaveStatusTarget
      target.textContent = message

      // Reset classes
      target.className = "text-sm mt-2"

      // Add new class if provided
      if (cssClass) {
        target.classList.add(cssClass)
      }

      // Use setVisible utility for consistent visibility management
      setVisible(target, !!message)
    }
  }

  displayFieldError(element, message) {
    // Find or create error element near the field
    const errorContainer = this.findOrCreateFieldErrorElement(element)

    if (errorContainer) {
      errorContainer.textContent = message
      errorContainer.classList.add('text-red-600', 'text-sm', 'mt-1')
      setVisible(errorContainer, true)
    }
  }

  clearFieldError(event) {
    this.clearFieldErrorNear(event.target)
  }

  clearFieldErrorNear(element) {
    const errorContainer = this.findFieldErrorElement(element)
    if (errorContainer) {
      errorContainer.textContent = ''
      setVisible(errorContainer, false)
    }
  }

  findFieldErrorElement(element) {
    // First look for an existing field error element with a data-field attribute
    const fieldName = element.name

    // Look for error elements that are siblings of the input
    const parent = element.parentElement
    if (parent) {
      const errorElem = parent.querySelector(`.field-error-message[data-field="${fieldName}"]`)
      if (errorElem) return errorElem

      // Also look for any field error elements without a specific data field that are siblings
      const genericErrorElem = parent.querySelector('.field-error-message:not([data-field])')
      if (genericErrorElem) return genericErrorElem
    }

    // Look more broadly for any target
    return this.fieldErrorTargets.find(target =>
      target.dataset.field === fieldName || !target.dataset.field
    )
  }

  findOrCreateFieldErrorElement(element) {
    // First try to find an existing error element
    const existing = this.findFieldErrorElement(element)
    if (existing) return existing

    // If not found, create a new one
    const errorElem = document.createElement('p')
    errorElem.className = 'field-error-message text-red-600 text-sm mt-1'
    errorElem.dataset.field = element.name

    // Insert after the input element
    const parent = element.parentElement
    if (parent) {
      parent.insertBefore(errorElem, element.nextSibling)
      return errorElem
    }

    return null
  }
}

// Apply target safety mixin

export default AutosaveController
