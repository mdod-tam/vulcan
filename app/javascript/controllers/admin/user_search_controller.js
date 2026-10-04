import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"
import { debounce } from "../../utils/debounce"

class UserSearchController extends Controller {
  static targets = [
    "searchInput",
    "searchResults",
    "guardianForm",
    "createButton",
    "guardianFormField",
    "clearSearchButton",
    "guardianReview"
  ]

  static outlets = ["guardian-picker", "adult-picker"]

  static values = {
    searchUrl: String,
    createUserUrl: String,
    role: { type: String, default: "guardian" }
  }

  connect() {
    this.debouncedSearch = debounce(q => this.navigateToSearch(q), 300)
  }

  performSearch(event) {
    const q = event.target.value.trim()

    if (q.length === 0) {
      this.clearResults()
      return
    }

    this.debouncedSearch(q)
  }

  navigateToSearch(q) {
    if (!this.hasSearchResultsTarget) return
    const turboFrame = this.searchResultsTarget

    // frame_id directs the Turbo response to this search frame.
    const frameId = turboFrame.id || ''
    const searchUrl = `${this.searchUrlValue}?q=${encodeURIComponent(q)}&role=${this.roleValue}&frame_id=${encodeURIComponent(frameId)}`

    // clearResults() hides the frame, so show it before navigation.
    setVisible(turboFrame, true)
    turboFrame.src = searchUrl
  }

  clearResults() {
    this.debouncedSearch.cancel()
    if (this.hasSearchResultsTarget) {
      const target = this.searchResultsTarget
      target.removeAttribute('src')
      target.innerHTML = '<p class="text-sm text-gray-500 p-3">Type a name or email to search for guardians.</p>'
      setVisible(target, false)
    }
  }

  clearSearchAndShowForm() {
    if (this.hasSearchInputTarget) {
      const input = this.searchInputTarget
      input.value = ""
      input.focus()
    }

    this.clearResults()

    // Keep the guardian selection after a successful create.
  }

  showCreateForm() {
    const form = this.element.querySelector('[data-admin-user-search-target="guardianForm"]') ||
      this.element.querySelector('.guardian-search-form')

    if (form) {
      form.style.display = 'block'
      form.style.visibility = 'visible'
    } else if (process.env.NODE_ENV !== 'production') {
      console.error('Guardian form not found')
    }
  }

  clearSearchAndSelection() {
    if (this.hasSearchInputTarget) {
      const input = this.searchInputTarget
      input.value = ""
      input.focus()
    }

    this.clearResults()

    if (this.hasGuardianPickerOutlet) {
      this.guardianPickerOutlet.clearSelection()
    }
  }

  async createGuardian(event) {
    event.preventDefault()

    // Build a separate payload from the nested guardian fields.
    const formData = new FormData()

    const guardianFields = this.element.querySelectorAll('input[name^="guardian_attributes"], select[name^="guardian_attributes"]')

    if (guardianFields.length === 0) {
      if (process.env.NODE_ENV !== 'production') console.error('Guardian form fields not found')
      return
    }

    guardianFields.forEach(field => {
      if (field.type === 'radio' || field.type === 'checkbox') {
        if (field.checked) {
          const fieldName = field.name.replace('guardian_attributes[', '').replace(']', '')
          formData.append(fieldName, field.value)
        }
      } else if (field.value.trim() !== '') {
        const fieldName = field.name.replace('guardian_attributes[', '').replace(']', '')
        formData.append(fieldName, field.value)
      }
    })

    // Contact flags sit outside guardian_attributes and need separate payload entries.
    const noEmailCheckbox = this.element.querySelector('input[type="checkbox"][name="guardian_no_email_address"]')
    const noPhoneCheckbox = this.element.querySelector('input[type="checkbox"][name="guardian_no_phone_number"]')
    if (noEmailCheckbox?.checked) {
      formData.append('guardian_no_email_address', '1')
      formData.append('no_email_address', '1')
    }
    if (noPhoneCheckbox?.checked) {
      formData.append('guardian_no_phone_number', '1')
      formData.append('no_phone_number', '1')
    }

    this.clearFieldErrors()

    const validationResult = await this.validateBeforeSubmit(formData)
    if (!validationResult.valid) {
      this.handleValidationErrors(validationResult.errors)
      return
    }

    this.element.querySelectorAll('[name^="guardian_identity_"]').forEach(field => {
      formData.set(field.name.replace("guardian_identity_", "identity_"), field.value)
    })
    const button = event.currentTarget
    if (button.name) formData.set(button.name, button.value)
    const originalText = button.textContent
    button.disabled = true
    try {
      const response = await fetch(this.hasCreateUserUrlValue ? this.createUserUrlValue : '/admin/users', {
        method: 'POST', body: formData, credentials: 'same-origin',
        headers: { Accept: 'application/json, text/html', 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '' }
      })
      if (response.redirected || response.status === 401) {
        this.showGeneralError('Your session expired. Sign in again before saving the guardian.')
      } else if (response.ok) {
        this.guardianReviewTarget.replaceChildren()
        await this.handleSuccess(await response.json())
      } else if (response.status === 422) {
        this.guardianReviewTarget.innerHTML = await response.text()
        this.guardianReviewTarget.querySelector('[tabindex="-1"]')?.focus()
      } else {
        this.showGeneralError('Unable to save the guardian. Please try again.')
      }
    } catch (error) {
      this.showGeneralError('Guardian could not be saved. Check your connection and try again.')
    } finally {
      button.disabled = false
      button.textContent = originalText
    }
  }

  selectUser(event) {
    event.preventDefault()
    const row = event.currentTarget
    const { userId, userName, userIneligible, ...userData } = row.dataset

    if (!userId || !userName) {
      if (process.env.NODE_ENV !== 'production') console.error("User data missing from selection")
      return
    }

    if (userIneligible === "true" || row.getAttribute('aria-disabled') === 'true') {
      return
    }

    if (this.hasAdultPickerOutlet) {
      const displayHTML = this.buildAdultDisplayHTML(this.escapeHtml(userName), userData)
      this.adultPickerOutlet.selectAdult(userId, displayHTML, userData)
    } else if (this.hasGuardianPickerOutlet) {
      const displayHTML = this.buildUserDisplayHTML(this.escapeHtml(userName), userData)
      this.guardianPickerOutlet.selectGuardian(userId, displayHTML)
    }

    this.clearResults()
  }

  buildUserDisplayHTML(userName, userData) {
    const { userEmail, userPhone, userAddress1, userAddress2, userCity, userState, userZip, userDependentsCount = '0' } = userData

    // Escape contact and address values before HTML interpolation. The caller escapes userName.
    const safeEmail = userEmail ? this.escapeHtml(userEmail) : ''
    const safePhone = userPhone ? this.escapeHtml(userPhone) : ''
    const safeAddress1 = userAddress1 ? this.escapeHtml(userAddress1) : ''
    const safeAddress2 = userAddress2 ? this.escapeHtml(userAddress2) : ''
    const safeCity = userCity ? this.escapeHtml(userCity) : ''
    const safeState = userState ? this.escapeHtml(userState) : ''
    const safeZip = userZip ? this.escapeHtml(userZip) : ''

    let html = `<span class="font-medium">${userName}</span>`

    const contactInfo = []
    if (safeEmail) contactInfo.push(`<span class="text-indigo-700">${safeEmail}</span>`)
    if (safePhone) contactInfo.push(`<span class="text-gray-600">Phone: ${safePhone}</span>`)

    if (contactInfo.length > 0) {
      html += `<div class="text-sm text-gray-600 mt-1">${contactInfo.join(' • ')}</div>`
    }

    const addressParts = [safeAddress1, safeAddress2, safeCity, safeState, safeZip].filter(Boolean)
    if (addressParts.length > 0) {
      html += `<div class="text-sm text-gray-600 mt-1">${addressParts.join(', ')}</div>`
    } else {
      html += `<div class="text-sm text-gray-600 mt-1 italic">No address information available</div>`
    }

    const dependentsCount = parseInt(userDependentsCount) || 0
    const dependentsText = dependentsCount === 1 ? "1 dependent" : `${dependentsCount} dependents`
    html += `<div class="text-sm text-gray-600 mt-1">Currently has ${dependentsText}</div>`

    return html
  }

  buildAdultDisplayHTML(userName, userData) {
    const { userEmail, userPhone, userAddress1, userCity, userState, userZip, userDob, userProducts } = userData

    const safeEmail = userEmail ? this.escapeHtml(userEmail) : ''
    const safePhone = userPhone ? this.escapeHtml(userPhone) : ''
    const safeAddress1 = userAddress1 ? this.escapeHtml(userAddress1) : ''
    const safeCity = userCity ? this.escapeHtml(userCity) : ''
    const safeState = userState ? this.escapeHtml(userState) : ''
    const safeZip = userZip ? this.escapeHtml(userZip) : ''
    const safeDob = userDob ? this.escapeHtml(userDob) : ''
    const safeProducts = userProducts ? this.escapeHtml(userProducts) : ''

    let html = `<span class="font-medium">${userName}</span>`

    if (safeDob) {
      html += `<div class="text-sm text-gray-600 mt-1">DOB: ${safeDob}</div>`
    }

    const contactInfo = []
    if (safeEmail) contactInfo.push(`<span class="text-indigo-700">${safeEmail}</span>`)
    if (safePhone) contactInfo.push(`<span class="text-gray-600">Phone: ${safePhone}</span>`)
    if (contactInfo.length > 0) {
      html += `<div class="text-sm text-gray-600 mt-1">${contactInfo.join(' &bull; ')}</div>`
    }

    const addressParts = [safeAddress1, safeCity, safeState, safeZip].filter(Boolean)
    if (addressParts.length > 0) {
      html += `<div class="text-sm text-gray-600 mt-1">${addressParts.join(', ')}</div>`
    }

    if (safeProducts) {
      html += `<div class="text-sm text-gray-500 mt-1">Last products: ${safeProducts}</div>`
    }

    return html
  }

  escapeHtml(unsafe) {
    return unsafe
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;")
  }

  async validateBeforeSubmit(data) {
    const firstName = data instanceof FormData ? data.get('first_name') : data.first_name
    const lastName = data instanceof FormData ? data.get('last_name') : data.last_name
    const email = data instanceof FormData ? data.get('email') : data.email
    const phone = data instanceof FormData ? data.get('phone') : data.phone
    const noEmail = this.element.querySelector('input[type="checkbox"][name="guardian_no_email_address"]')?.checked === true
    const noPhone = this.element.querySelector('input[type="checkbox"][name="guardian_no_phone_number"]')?.checked === true

    if (!firstName || !lastName) {
      return {
        valid: false,
        errors: {
          first_name: !firstName ? 'First name is required' : null,
          last_name: !lastName ? 'Last name is required' : null
        }
      }
    }

    if (!noEmail && !email) {
      return {
        valid: false,
        errors: { email: 'Email is required' }
      }
    }

    if (!noPhone && !phone) {
      return {
        valid: false,
        errors: { phone: 'Phone is required' }
      }
    }

    return { valid: true }
  }

  clearFieldErrors() {
    this.element.querySelectorAll('input.border-red-500').forEach(input => {
      input.classList.remove('border-red-500')
    })

    this.element.querySelectorAll('.field-error-message').forEach(errorEl => {
      errorEl.remove()
    })
  }

  showGeneralError(message) {
    const errorEl = document.createElement('p')
    errorEl.className = 'field-error-message text-red-600 text-sm mt-2'
    errorEl.setAttribute('role', 'alert')
    errorEl.textContent = message
    const container = this.hasCreateButtonTarget
      ? (this.createButtonTarget.closest('div, form, fieldset') || this.element)
      : this.element
    container.appendChild(errorEl)
  }

  handleValidationErrors(errors) {
    let firstErrorInput = null

    Object.entries(errors).forEach(([field, message]) => {
      if (message) {
        const input = this.element.querySelector(`input[name="guardian_attributes[${field}]"], select[name="guardian_attributes[${field}]"], textarea[name="guardian_attributes[${field}]"]`)
        if (input) {
          input.classList.add('border-red-500', 'border-2')
          input.setAttribute('aria-invalid', 'true')

          const existingError = input.parentElement.querySelector('.field-error-message')
          if (existingError) {
            existingError.remove()
          }

          const errorEl = document.createElement('div')
          errorEl.className = 'field-error-message text-red-600 text-sm mt-1 flex items-start gap-1'
          errorEl.setAttribute('role', 'alert')
          errorEl.innerHTML = `
            <svg class="w-4 h-4 flex-shrink-0 mt-0.5" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
              <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd"/>
            </svg>
            <span>${this.escapeHtml(message)}</span>
          `
          input.parentElement.appendChild(errorEl)

          if (!firstErrorInput) {
            firstErrorInput = input
          }
        }
      }
    })

    if (firstErrorInput) {
      firstErrorInput.scrollIntoView({ behavior: 'smooth', block: 'center' })
      firstErrorInput.focus()
    }
  }

  handleSuccess(data) {
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

  disconnect() {
    this.debouncedSearch.cancel()
  }
}

export default UserSearchController
