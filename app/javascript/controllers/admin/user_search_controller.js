import BaseFormController from "../base/form_controller"
import { railsRequest } from "../../services/rails_request"
import { applyTargetSafety } from "../../mixins/target_safety"
import { setVisible } from "../../utils/visibility"

class UserSearchController extends BaseFormController {
  static targets = [
    "searchInput",
    "searchResults",
    "guardianForm",
    "createButton",
    "guardianFormField",
    "clearSearchButton"
  ]

  static outlets = ["guardian-picker"]

  static values = {
    searchUrl: String,
    createUserUrl: String,
    defaultRole: { type: String, default: "guardian" }
  }

  connect() {
    super.connect()

    // Add debounced search listener using our new pattern
    if (this.safeTarget('searchInput')) {
      this.addDebouncedListener(
        this.searchInputTarget,
        'input',
        this.performSearch,
        300
      )
    }
  }

  async performSearch(event) {
    const q = event.target.value.trim()

    if (q.length === 0) {
      this.clearResults()
      return
    }

    // Use Turbo Frame navigation
    this.navigateToSearch(q)
  }

  navigateToSearch(q) {
    // Find the turbo frame that should handle the search results
    const turboFrame = this.safeTarget('searchResults')
    if (!turboFrame) return

    // Construct the search URL
    const searchUrl = `${this.searchUrlValue}?q=${encodeURIComponent(q)}&role=${this.defaultRoleValue}`
    
    // Set the turbo frame's src to trigger navigation
    turboFrame.src = searchUrl
  }

  clearResults() {
    this.withTarget('searchResults', (target) => {
      // Clear the turbo frame by removing its src
      target.removeAttribute('src')
      target.innerHTML = ""
      setVisible(target, false)
    })
  }



  clearSearchAndShowForm() {
    this.withTarget('searchInput', (input) => {
      input.value = ""
      input.focus()
    })

    this.clearResults()

    // DON'T clear the guardian selection here - that would undo the selection we just made!
    // The guardian picker outlet should maintain its selected state
  }

  showCreateForm() {
    // Try multiple approaches to find and show the form
    const form = this.element.querySelector('[data-admin-user-search-target="guardianForm"]') ||
      this.element.querySelector('.guardian-search-form')

    if (form) {
      form.style.display = 'block'
      form.style.visibility = 'visible'
    } else {
      console.error('Guardian form not found')
    }
  }

  // Separate method for when we actually want to clear everything
  clearSearchAndSelection() {
    this.withTarget('searchInput', (input) => {
      input.value = ""
      input.focus()
    })

    this.clearResults()

    if (this.hasGuardianPickerOutlet) {
      this.guardianPickerOutlet.clearSelection()
    }
  }

  // Handle guardian creation from button click events (matching HTML and documentation)
  async createGuardian(event) {
    event.preventDefault()

    // Collect form data from guardian fields since they're not in an actual form element
    const formData = new FormData()

    // Find all guardian input fields within our controller element
    const guardianFields = this.element.querySelectorAll('input[name^="guardian_attributes"], select[name^="guardian_attributes"]')

    if (guardianFields.length === 0) {
      console.error('Guardian form fields not found')
      return
    }

    // Collect all field values and convert guardian_attributes[field] to direct field names
    guardianFields.forEach(field => {
      if (field.type === 'radio' || field.type === 'checkbox') {
        if (field.checked) {
          // Convert guardian_attributes[field_name] to just field_name
          const fieldName = field.name.replace('guardian_attributes[', '').replace(']', '')
          formData.append(fieldName, field.value)
        }
      } else if (field.value.trim() !== '') {
        // Convert guardian_attributes[field_name] to just field_name
        const fieldName = field.name.replace('guardian_attributes[', '').replace(']', '')
        formData.append(fieldName, field.value)
      }
    })

    // Clear any previous errors
    this.clearFieldErrors()

    // Validate required fields
    const validationResult = await this.validateBeforeSubmit(formData)
    if (!validationResult.valid) {
      this.handleValidationErrors(validationResult.errors)
      return
    }

    try {
      // Show loading state on the button
      const button = event.target
      const originalText = button.textContent
      button.disabled = true
      button.textContent = 'Creating...'

      // Convert FormData to JSON object for Rails controller
      const userData = {}
      for (const [key, value] of formData.entries()) {
        userData[key] = value
      }

      const result = await railsRequest.perform({
        method: 'post',
        url: this.hasCreateUserUrlValue ? this.createUserUrlValue : '/admin/users',
        body: userData,
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json'
        },
        key: 'create-guardian'
      })

      if (result.success) {
        await this.handleSuccess(result.data)
        // Restore button state after success
        button.disabled = false
        button.textContent = originalText
      } else {
        throw new Error('Guardian creation failed')
      }

    } catch (error) {
      console.error('Guardian creation error:', error)

      // Restore button state on error
      const button = event.target
      button.disabled = false
      button.textContent = 'Save Guardian'
    }
  }

  selectUser(event) {
    event.preventDefault()
    const { userId, userName, ...userData } = event.currentTarget.dataset

    if (!userId || !userName) {
      console.error("User data missing from selection")
      return
    }

    // Use safe HTML escaping for security
    const displayHTML = this.buildUserDisplayHTML(this.escapeHtml(userName), userData)

    if (this.hasGuardianPickerOutlet) {
      this.guardianPickerOutlet.selectGuardian(userId, displayHTML)
    }

    this.clearResults()
  }

  buildUserDisplayHTML(userName, userData) {
    const { userEmail, userPhone, userAddress1, userAddress2, userCity, userState, userZip, userDependentsCount = '0' } = userData

    // Escape all user data for XSS prevention
    const safeEmail = userEmail ? this.escapeHtml(userEmail) : ''
    const safePhone = userPhone ? this.escapeHtml(userPhone) : ''
    const safeAddress1 = userAddress1 ? this.escapeHtml(userAddress1) : ''
    const safeAddress2 = userAddress2 ? this.escapeHtml(userAddress2) : ''
    const safeCity = userCity ? this.escapeHtml(userCity) : ''
    const safeState = userState ? this.escapeHtml(userState) : ''
    const safeZip = userZip ? this.escapeHtml(userZip) : ''

    let html = `<span class="font-medium">${userName}</span>`

    // Contact info
    const contactInfo = []
    if (safeEmail) contactInfo.push(`<span class="text-indigo-700">${safeEmail}</span>`)
    if (safePhone) contactInfo.push(`<span class="text-gray-600">Phone: ${safePhone}</span>`)

    if (contactInfo.length > 0) {
      html += `<div class="text-sm text-gray-600 mt-1">${contactInfo.join(' • ')}</div>`
    }

    // Address
    const addressParts = [safeAddress1, safeAddress2, safeCity, safeState, safeZip].filter(Boolean)
    if (addressParts.length > 0) {
      html += `<div class="text-sm text-gray-600 mt-1">${addressParts.join(', ')}</div>`
    } else {
      html += `<div class="text-sm text-gray-600 mt-1 italic">No address information available</div>`
    }

    // Dependents
    const dependentsCount = parseInt(userDependentsCount) || 0
    const dependentsText = dependentsCount === 1 ? "1 dependent" : `${dependentsCount} dependents`
    html += `<div class="text-sm text-gray-600 mt-1">Currently has ${dependentsText}</div>`

    return html
  }

  // XSS prevention helper
  escapeHtml(unsafe) {
    return unsafe
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;")
  }

  // Override from BaseFormController for custom validation
  async validateBeforeSubmit(data) {
    // Handle both FormData and plain objects
    const firstName = data instanceof FormData ? data.get('first_name') : data.first_name
    const lastName = data instanceof FormData ? data.get('last_name') : data.last_name
    const email = data instanceof FormData ? data.get('email') : data.email

    if (!firstName || !lastName || !email) {
      return {
        valid: false,
        errors: {
          first_name: !firstName ? 'First name is required' : null,
          last_name: !lastName ? 'Last name is required' : null,
          email: !email ? 'Email is required' : null
        }
      }
    }
    return { valid: true }
  }

  // Clear field validation errors
  clearFieldErrors() {
    // Remove error styling from inputs
    this.element.querySelectorAll('input.border-red-500').forEach(input => {
      input.classList.remove('border-red-500')
    })

    // Remove error messages
    this.element.querySelectorAll('.field-error-message').forEach(errorEl => {
      errorEl.remove()
    })
  }

  // Handle validation errors display
  handleValidationErrors(errors) {
    Object.entries(errors).forEach(([field, message]) => {
      if (message) {
        // Look for input with guardian_attributes format
        const input = this.element.querySelector(`input[name="guardian_attributes[${field}]"], select[name="guardian_attributes[${field}]"]`)
        if (input) {
          input.classList.add('border-red-500')
          // Try to find or create error display
          let errorEl = input.parentElement.querySelector('.field-error-message')
          if (!errorEl) {
            errorEl = document.createElement('div')
            errorEl.className = 'field-error-message text-red-600 text-sm mt-1'
            input.parentElement.appendChild(errorEl)
          }
          errorEl.textContent = message
        }
      }
    })
  }

  // Override from BaseFormController for success handling
  async handleSuccess(data) {
    if (data.user) {
      this.handleGuardianCreationSuccess(data)
    } else {
      super.handleSuccess(data)
    }
  }

  handleGuardianCreationSuccess(data) {
    const { user } = data
    const displayHTML = this.buildUserDisplayHTML(
      this.escapeHtml(`${user.first_name} ${user.last_name}`),
      {
        userEmail: user.email,
        userPhone: user.phone,
        userAddress1: user.physical_address_1,
        userAddress2: user.physical_address_2,
        userCity: user.city,
        userState: user.state,
        userZip: user.zip_code,
        userDependentsCount: '0'
      }
    )

    if (this.hasGuardianPickerOutlet) {
      this.guardianPickerOutlet.selectGuardian(user.id.toString(), displayHTML)
    }

    this.clearSearchAndShowForm()
  }

  

  // Override disconnect to add event handler cleanup
  disconnect() {
    // Clean up managed event listeners
    this.cleanupAllEventHandlers()

    // Call parent disconnect
    super.disconnect()
  }

  // Add event handler management mixin methods
  addDebouncedListener(element, event, handler, wait = 300) {
    if (!element) return

    const debounced = this.debounce(handler.bind(this), wait)
    element.addEventListener(event, debounced)

    // Store for cleanup
    this._managedListeners = this._managedListeners || []
    this._managedListeners.push({ element, event, handler: debounced })
  }

  cleanupAllEventHandlers() {
    if (this._managedListeners) {
      this._managedListeners.forEach(({ element, event, handler }) => {
        element.removeEventListener(event, handler)
      })
      this._managedListeners = []
    }
  }

  debounce(func, wait) {
    let timeout
    return function executedFunction(...args) {
      const later = () => {
        clearTimeout(timeout)
        func(...args)
      }
      clearTimeout(timeout)
      timeout = setTimeout(later, wait)
    }
  }
}

// Apply target safety mixin
applyTargetSafety(UserSearchController)

export default UserSearchController
