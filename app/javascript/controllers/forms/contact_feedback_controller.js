import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

/**
 * Contact Feedback Controller
 * 
 * Shows confirmation messages like "We will call you at XXX-XXX-XXXX"
 * based on the selected contact method and entered contact info.
 * 
 * Usage:
 *   <div data-controller="contact-feedback">
 *     <input data-contact-feedback-target="phone" ...>
 *     <input data-contact-feedback-target="email" ...>
 *     <input type="radio" name="contact_method" value="call" 
 *            data-action="change->contact-feedback#updateFeedback">
 *     <div data-contact-feedback-target="feedback"></div>
 *   </div>
 */
export default class ContactFeedbackController extends Controller {
  static targets = [
    "phone",           // Phone number input
    "email",           // Email input
    "emailWrapper",    // Wrapper around email field (scoped per controller instance)
    "phoneWrapper",    // Wrapper around phone field
    "phoneTypeFieldset", // Preferred contact method fieldset
    "address1",        // Street address line 1
    "address2",        // Street address line 2 (optional)
    "city",            // City
    "state",           // State
    "zipCode",         // ZIP code
    "feedback",        // Container for feedback message
    "contactMethod",   // Radio buttons for how to contact (call, text, videophone, email, mail)
    "deliveryMethod",  // Radio buttons for where to send official docs (email vs mail)
    "deliveryFeedback" // Container for delivery preference feedback
  ]

  static values = {
    // Configurable feedback messages for preferred contact method
    callMessage: { type: String, default: "We will call you at" },
    textMessage: { type: String, default: "We will text you at" },
    videophoneMessage: { type: String, default: "We will call you using ASL at" },
    emailMessage: { type: String, default: "We will email you at" },
    mailMessage: { type: String, default: "We will send mail to your address" },
    // Configurable feedback messages for document delivery preference
    deliveryEmailMessage: { type: String, default: "We will email official program documents to" },
    deliveryMailMessage: { type: String, default: "We will mail official program documents to" }
  }

  connect() {
    // Store bound method references for cleanup
    this._boundUpdateFeedback = this.updateFeedback.bind(this)
    this._boundUpdateDeliveryFeedback = this.updateDeliveryFeedback.bind(this)
    
    // Set up listeners on input fields for real-time updates
    this._setupInputListeners()
    
    // Restore no-contact checkbox UI after validation failure re-render
    this._syncNoContactCheckboxState()

    // Initial update - show feedback on page load
    this.updateFeedback()
    this.updateDeliveryFeedback()
  }

  disconnect() {
    this._teardownInputListeners()
  }

  /**
   * Toggle email field visibility when "no email" checkbox is checked
   */
  toggleEmailField(event) {
    const checkbox = event.target
    const emailInput = this._emailInput()
    const emailWrapper = this._emailWrapper()

    if (!emailInput || !emailWrapper) return

    if (checkbox.checked) {
      emailWrapper.classList.add('hidden')
      emailInput.required = false
      emailInput.removeAttribute('aria-required')
      emailInput.value = ''
      emailInput.disabled = true
      this._selectLetterDelivery()
    } else {
      emailWrapper.classList.remove('hidden')
      emailInput.required = true
      emailInput.setAttribute('aria-required', 'true')
      emailInput.disabled = false
    }

    this.updateFeedback()
    this.updateDeliveryFeedback()
  }

  /**
   * Toggle phone field visibility when "no phone" checkbox is checked
   */
  togglePhoneField(event) {
    const checkbox = event.target
    const phoneInput = this._phoneInput()
    const phoneWrapper = this._phoneWrapper()
    const phoneTypeFieldset = this._phoneTypeFieldset()

    if (!phoneInput || !phoneWrapper) return

    if (checkbox.checked) {
      phoneWrapper.classList.add('hidden')
      phoneInput.required = false
      phoneInput.removeAttribute('aria-required')
      phoneInput.value = ''
      phoneInput.disabled = true
      if (phoneTypeFieldset) phoneTypeFieldset.classList.add('hidden')
      this._selectLetterDelivery()
    } else {
      phoneWrapper.classList.remove('hidden')
      phoneInput.required = true
      phoneInput.setAttribute('aria-required', 'true')
      phoneInput.disabled = false
      if (phoneTypeFieldset) phoneTypeFieldset.classList.remove('hidden')
    }

    this.updateFeedback()
    this.updateDeliveryFeedback()
  }

  /**
   * Dependent form: no-email checkbox selects guardian email strategy
   */
  toggleDependentNoEmail(event) {
    const checkbox = event.target
    const useGuardianEmail = this.element.querySelector('#use_guardian_email_checkbox')

    if (useGuardianEmail) {
      useGuardianEmail.checked = checkbox.checked
      useGuardianEmail.dispatchEvent(new Event('change', { bubbles: true }))
    }

    if (checkbox.checked) {
      this._selectLetterDelivery()
    }

    this.updateFeedback()
    this.updateDeliveryFeedback()
  }

  _selectLetterDelivery() {
    const letterRadio = this.element.querySelector('input[name="constituent[communication_preference]"][value="letter"]') ||
      this.element.querySelector('input[name="guardian_attributes[communication_preference]"][value="letter"]')
    if (letterRadio) {
      letterRadio.checked = true
      this.updateDeliveryFeedback()
    }
  }

  _syncNoContactCheckboxState() {
    const noEmailCheckbox = this._noEmailCheckbox()
    if (noEmailCheckbox?.checked) {
      this.toggleEmailField({ target: noEmailCheckbox })
    }

    const noPhoneCheckbox = this._noPhoneCheckbox()
    if (noPhoneCheckbox?.checked) {
      this.togglePhoneField({ target: noPhoneCheckbox })
    }
  }

  _emailInput() {
    if (this.hasEmailTarget) return this.emailTarget
    return this.element.querySelector('[data-contact-feedback-target="email"]')
  }

  _phoneInput() {
    if (this.hasPhoneTarget) return this.phoneTarget
    return this.element.querySelector('[data-contact-feedback-target="phone"]')
  }

  _emailWrapper() {
    if (this.hasEmailWrapperTarget) return this.emailWrapperTarget
    return this.element.querySelector('[data-contact-feedback-target="emailWrapper"]')
  }

  _phoneWrapper() {
    if (this.hasPhoneWrapperTarget) return this.phoneWrapperTarget
    return this.element.querySelector('[data-contact-feedback-target="phoneWrapper"]')
  }

  _phoneTypeFieldset() {
    if (this.hasPhoneTypeFieldsetTarget) return this.phoneTypeFieldsetTarget
    return this.element.querySelector('[data-contact-feedback-target="phoneTypeFieldset"]')
  }

  _noEmailCheckbox() {
    return this.element.querySelector('input[type="checkbox"][name="no_email_address"]') ||
      this.element.querySelector('input[type="checkbox"][name="guardian_no_email_address"]')
  }

  _noPhoneCheckbox() {
    return this.element.querySelector('input[type="checkbox"][name="no_phone_number"]') ||
      this.element.querySelector('input[type="checkbox"][name="guardian_no_phone_number"]')
  }

  _noEmailChecked() {
    return this._noEmailCheckbox()?.checked === true
  }

  _noPhoneChecked() {
    return this._noPhoneCheckbox()?.checked === true
  }

  /**
   * Listeners on phone/email/address inputs for real-time feedback updates
   */
  _setupInputListeners() {
    const phoneInput = this._phoneInput()
    if (phoneInput) {
      phoneInput.addEventListener("input", this._boundUpdateFeedback)
      phoneInput.addEventListener("change", this._boundUpdateFeedback)
    }
    
    const emailInput = this._emailInput()
    if (emailInput) {
      emailInput.addEventListener("input", this._boundUpdateFeedback)
      emailInput.addEventListener("change", this._boundUpdateFeedback)
      emailInput.addEventListener("input", this._boundUpdateDeliveryFeedback)
      emailInput.addEventListener("change", this._boundUpdateDeliveryFeedback)
    }
    
    // Set up listeners for address fields to update delivery feedback
    const addressTargets = ['address1', 'address2', 'city', 'state', 'zipCode']
    addressTargets.forEach(targetName => {
      const target = this[`${targetName}Target`]
      if (target) {
        target.addEventListener("input", this._boundUpdateDeliveryFeedback)
        target.addEventListener("change", this._boundUpdateDeliveryFeedback)
      }
    })
  }

  _teardownInputListeners() {
    const phoneInput = this._phoneInput()
    if (phoneInput) {
      phoneInput.removeEventListener("input", this._boundUpdateFeedback)
      phoneInput.removeEventListener("change", this._boundUpdateFeedback)
    }
    
    const emailInput = this._emailInput()
    if (emailInput) {
      emailInput.removeEventListener("input", this._boundUpdateFeedback)
      emailInput.removeEventListener("change", this._boundUpdateFeedback)
      emailInput.removeEventListener("input", this._boundUpdateDeliveryFeedback)
      emailInput.removeEventListener("change", this._boundUpdateDeliveryFeedback)
    }
    
    // Remove listeners from address fields
    const addressTargets = ['address1', 'address2', 'city', 'state', 'zipCode']
    addressTargets.forEach(targetName => {
      const target = this[`${targetName}Target`]
      if (target) {
        target.removeEventListener("input", this._boundUpdateDeliveryFeedback)
        target.removeEventListener("change", this._boundUpdateDeliveryFeedback)
      }
    })
  }

  /**
   * Update the contact method feedback based on selection
   * Called by radio button change events and input changes
   */
  updateFeedback() {
    if (!this.hasFeedbackTarget) return
    
    const selectedMethod = this._getSelectedContactMethod()
    if (!selectedMethod) {
      setVisible(this.feedbackTarget, false)
      return
    }
    
    const feedback = this._buildContactFeedback(selectedMethod)
    
    if (feedback) {
      this.feedbackTarget.innerHTML = feedback.html
      this.feedbackTarget.className = feedback.className
      setVisible(this.feedbackTarget, true)
      // Note: aria-live="polite" and aria-atomic="true" are set in HTML for reliability
    } else {
      setVisible(this.feedbackTarget, false)
    }
  }

  /**
   * Update delivery method feedback (email vs mail for official docs)
   */
  updateDeliveryFeedback() {
    const deliveryFeedback = this.element.querySelector('[data-contact-feedback-target="deliveryFeedback"]')
    if (!deliveryFeedback) return
    
    const selectedDelivery = this._getSelectedDeliveryMethod()
    if (!selectedDelivery) {
      setVisible(deliveryFeedback, false)
      return
    }
    
    const feedback = this._buildDeliveryFeedback(selectedDelivery)
    
    if (feedback) {
      deliveryFeedback.innerHTML = feedback.html
      deliveryFeedback.className = feedback.className
      setVisible(deliveryFeedback, true)
      // Note: aria-live="polite" and aria-atomic="true" are set in HTML for reliability
    } else {
      setVisible(deliveryFeedback, false)
    }
  }

  /**
   * Get the currently selected contact method
   * @returns {string|null} The selected contact method value
   */
  _getSelectedContactMethod() {
    // Check for radio buttons with specific name patterns
    const radioNames = [
      'constituent[phone_type]',
      'guardian_attributes[phone_type]',
      'contact_method'
    ]
    
    for (const name of radioNames) {
      const checked = this.element.querySelector(`input[name="${name}"]:checked`)
      if (checked) return checked.value
    }
    
    // Fall back to contactMethod targets
    if (this.hasContactMethodTarget) {
      const checked = this.contactMethodTargets.find(r => r.checked)
      return checked?.value || null
    }
    
    return null
  }

  /**
   * Get the currently selected delivery method
   * @returns {string|null} The selected delivery method value
   */
  _getSelectedDeliveryMethod() {
    const radioNames = [
      'constituent[communication_preference]',
      'guardian_attributes[communication_preference]',
      'delivery_method'
    ]
    
    for (const name of radioNames) {
      const checked = this.element.querySelector(`input[name="${name}"]:checked`)
      if (checked) return checked.value
    }
    
    if (this.hasDeliveryMethodTarget) {
      const checked = this.deliveryMethodTargets.find(r => r.checked)
      return checked?.value || null
    }
    
    return null
  }

  /**
   * Build the contact method feedback HTML
   * @param {string} method The preferred contact method (voice, text, videophone, email, letter)
   * @returns {Object|null} Object with html and className, or null if no feedback
   */
  _buildContactFeedback(method) {
    const phoneInput = this._phoneInput()
    const emailInput = this._emailInput()
    const phone = phoneInput ? this._formatPhone(phoneInput.value) : null
    const email = emailInput ? emailInput.value : null
    
    // Base classes for feedback - accessible, visually distinct
    const baseClassName = "mt-2 p-3 rounded-md text-sm font-medium flex items-center gap-2"
    const successClassName = `${baseClassName} bg-teal-50 text-teal-800 border border-teal-200`
    const warningClassName = `${baseClassName} bg-amber-50 text-amber-800 border border-amber-200`
    
    // Icon for checkmark
    const checkIcon = `<svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
      <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
    </svg>`
    const guardianPhoneFeedback = () => {
      if (!this._usesGuardianPhonePath()) return null

      return {
        html: `${checkIcon}<span>We will use the guardian phone path.</span>`,
        className: successClassName
      }
    }
    const guardianPhoneFallback = guardianPhoneFeedback()
    
    switch (method) {
      case 'voice':
        if (this._noPhoneChecked()) {
          return {
            html: `${checkIcon}<span>${this.mailMessageValue}</span>`,
            className: successClassName
          }
        }
        if (phone) {
          return {
            html: `${checkIcon}<span>${this.callMessageValue} <strong>${phone}</strong></span>`,
            className: successClassName
          }
        }
        if (guardianPhoneFallback) return guardianPhoneFallback
        return {
          html: `<span>Please enter a phone number above</span>`,
          className: warningClassName
        }
        
      case 'text':
        if (this._noPhoneChecked()) {
          return {
            html: `${checkIcon}<span>${this.mailMessageValue}</span>`,
            className: successClassName
          }
        }
        if (phone) {
          return {
            html: `${checkIcon}<span>${this.textMessageValue} <strong>${phone}</strong></span>`,
            className: successClassName
          }
        }
        if (guardianPhoneFallback) return guardianPhoneFallback
        return {
          html: `<span>Please enter a phone number above</span>`,
          className: warningClassName
        }
        
      case 'videophone':
        if (this._noPhoneChecked()) {
          return {
            html: `${checkIcon}<span>${this.mailMessageValue}</span>`,
            className: successClassName
          }
        }
        if (phone) {
          return {
            html: `${checkIcon}<span>${this.videophoneMessageValue} <strong>${phone}</strong></span>`,
            className: successClassName
          }
        }
        if (guardianPhoneFallback) return guardianPhoneFallback
        return {
          html: `<span>Please enter your videophone number above</span>`,
          className: warningClassName
        }
        
      case 'email':
        if (this._noEmailChecked()) {
          return {
            html: `${checkIcon}<span>${this.mailMessageValue}</span>`,
            className: successClassName
          }
        }
        if (email) {
          return {
            html: `${checkIcon}<span>${this.emailMessageValue} <strong>${email}</strong></span>`,
            className: successClassName
          }
        }
        return {
          html: `<span>Please enter an email address above</span>`,
          className: warningClassName
        }
        
      case 'letter':
        return {
          html: `${checkIcon}<span>${this.mailMessageValue}</span>`,
          className: successClassName
        }

      default:
        return null
    }
  }

  _usesGuardianPhonePath() {
    return this.element.querySelector('#use_guardian_phone_checkbox')?.checked === true
  }

  /**
   * Build the delivery method feedback HTML
   * @param {string} method The delivery method (email or letter/mail)
   * @returns {Object|null} Object with html and className, or null if no feedback
   */
  _buildDeliveryFeedback(method) {
    const emailInput = this._emailInput()
    const email = emailInput ? emailInput.value : null
    const address = this._buildFullAddress()
    
    const baseClassName = "mt-2 p-3 rounded-md text-sm font-medium flex items-start gap-2"
    const successClassName = `${baseClassName} bg-indigo-50 text-indigo-800 border border-indigo-200`
    const warningClassName = `${baseClassName} bg-amber-50 text-amber-800 border border-amber-200`
    
    const mailIcon = `<svg class="w-5 h-5 flex-shrink-0 mt-0.5" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
      <path d="M2.003 5.884L10 9.882l7.997-3.998A2 2 0 0016 4H4a2 2 0 00-1.997 1.884z"/>
      <path d="M18 8.118l-8 4-8-4V14a2 2 0 002 2h12a2 2 0 002-2V8.118z"/>
    </svg>`
    
    switch (method) {
      case 'email':
        if (this._noEmailChecked()) {
          if (address) {
            return {
              html: `${mailIcon}<div><div class="mb-1">${this.deliveryMailMessageValue}:</div><strong class="block">${address}</strong></div>`,
              className: successClassName
            }
          }
        }
        if (email) {
          return {
            html: `${mailIcon}<span>${this.deliveryEmailMessageValue} <strong>${email}</strong></span>`,
            className: successClassName
          }
        }
        return {
          html: `<span>Please enter an email address to receive official documents</span>`,
          className: warningClassName
        }
        
      case 'letter':
      case 'mail':
        if (address) {
          return {
            html: `${mailIcon}<div><div class="mb-1">${this.deliveryMailMessageValue}:</div><strong class="block">${address}</strong></div>`,
            className: successClassName
          }
        }
        return {
          html: `<span>Please enter your address above to receive official documents by mail</span>`,
          className: warningClassName
        }
        
      default:
        return null
    }
  }

  /**
   * Build full address string from address field targets
   * @returns {string|null} Full formatted address or null if incomplete
   */
  _buildFullAddress() {
    const address1 = this.hasAddress1Target ? this.address1Target.value.trim() : ''
    const address2 = this.hasAddress2Target ? this.address2Target.value.trim() : ''
    const city = this.hasCityTarget ? this.cityTarget.value.trim() : ''
    const state = this.hasStateTarget ? this.stateTarget.value.trim() : ''
    const zipCode = this.hasZipCodeTarget ? this.zipCodeTarget.value.trim() : ''
    
    // Require at least address1, city, state, and zip
    if (!address1 || !city || !state || !zipCode) {
      return null
    }
    
    // Build address lines
    const lines = []
    if (address2) {
      lines.push(`${address1}, ${address2}`)
    } else {
      lines.push(address1)
    }
    lines.push(`${city}, ${state} ${zipCode}`)
    
    return lines.join('<br>')
  }

  /**
   * Format phone number for display
   * @param {string} phone Raw phone number
   * @returns {string|null} Formatted phone or null if invalid
   */
  _formatPhone(phone) {
    if (!phone) return null
    
    // Strip non-digits
    const digits = phone.replace(/\D/g, '')
    
    // Handle 10-digit US phone
    if (digits.length === 10) {
      return `${digits.slice(0, 3)}-${digits.slice(3, 6)}-${digits.slice(6)}`
    }
    
    // Handle 11-digit with country code
    if (digits.length === 11 && digits.startsWith('1')) {
      const local = digits.slice(1)
      return `${local.slice(0, 3)}-${local.slice(3, 6)}-${local.slice(6)}`
    }
    
    // Return as-is if can't format
    return phone.trim() || null
  }
}
