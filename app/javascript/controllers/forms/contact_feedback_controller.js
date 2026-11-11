import { Controller } from "@hotwired/stimulus"
import { setVisible, hide, show } from "../../utils/visibility"

/**
 * Shows contact and document delivery feedback for the selected preferences.
 * Delivery feedback needs the address targets as well as the phone and email targets.
 */
export default class ContactFeedbackController extends Controller {
  static targets = [
    "phone",
    "email",
    "emailWrapper",
    "phoneWrapper",
    "phoneTypeFieldset",
    "address1",
    "address2",
    "city",
    "state",
    "zipCode",
    "feedback",
    "contactMethod",
    "deliveryMethod",
    "deliveryFeedback"
  ]

  static values = {
    callMessage: { type: String, default: "We will call you at" },
    textMessage: { type: String, default: "We will text you at" },
    videophoneMessage: { type: String, default: "We will call you using ASL at" },
    emailMessage: { type: String, default: "We will email you at" },
    mailMessage: { type: String, default: "We will send mail to your address" },
    deliveryEmailMessage: { type: String, default: "We will email official program documents to" },
    deliveryMailMessage: { type: String, default: "We will mail official program documents to" }
  }

  connect() {
    // Disconnect must remove the same listener references.
    this._boundUpdateFeedback = this.updateFeedback.bind(this)
    this._boundUpdateDeliveryFeedback = this.updateDeliveryFeedback.bind(this)
    this._boundNoContactCheckboxEvent = this._handleNoContactCheckboxEvent.bind(this)
    
    this._setupInputListeners()
    this._setupNoContactCheckboxListeners()
    
    // Apply restored no-contact choices after a validation error.
    this._syncNoContactCheckboxState()

    this.updateFeedback()
    this.updateDeliveryFeedback()
  }

  disconnect() {
    this._teardownInputListeners()
    this._teardownNoContactCheckboxListeners()
  }

  toggleEmailField(event) {
    const checkbox = event.target
    const emailInput = this._emailInput()
    const emailWrapper = this._emailWrapper()

    if (!emailInput || !emailWrapper) return

    if (checkbox.checked) {
      hide(emailWrapper)
      emailInput.required = false
      emailInput.removeAttribute('aria-required')
      emailInput.value = ''
      this._suppressContactField(emailInput)
      this._toggleRequiredLabel(emailWrapper, false)
      this._setCommunicationPreference('letter')
    } else {
      show(emailWrapper)
      emailInput.required = true
      emailInput.setAttribute('aria-required', 'true')
      this._restoreContactField(emailInput)
      this._toggleRequiredLabel(emailWrapper, true)
    }

    if (this._noPhoneChecked()) {
      this._applyNoPhoneContactType()
    }

    this.updateFeedback()
    this.updateDeliveryFeedback()
  }

  togglePhoneField(event) {
    const checkbox = event.target
    const phoneInput = this._phoneInput()
    const phoneWrapper = this._phoneWrapper()
    const phoneTypeFieldset = this._phoneTypeFieldset()

    if (!phoneInput || !phoneWrapper) return

    if (checkbox.checked) {
      hide(phoneWrapper)
      phoneInput.required = false
      phoneInput.removeAttribute('aria-required')
      phoneInput.value = ''
      this._suppressContactField(phoneInput)
      this._toggleRequiredLabel(phoneWrapper, false)
      if (phoneTypeFieldset) hide(phoneTypeFieldset)
      this._applyNoPhoneContactType()
      if (this._shouldUseLetterDelivery()) {
        this._setCommunicationPreference('letter')
      }
    } else {
      show(phoneWrapper)
      phoneInput.required = true
      phoneInput.setAttribute('aria-required', 'true')
      this._restoreContactField(phoneInput)
      this._toggleRequiredLabel(phoneWrapper, true)
      if (phoneTypeFieldset) show(phoneTypeFieldset)
      this._restorePhoneTypeSelection()
    }

    this.updateFeedback()
    this.updateDeliveryFeedback()
  }

  // A dependent without email uses the guardian email path and letter delivery.
  toggleDependentNoEmail(event) {
    const checkbox = event.target
    const useGuardianEmail = this.element.querySelector('#use_guardian_email_checkbox')

    if (useGuardianEmail) {
      useGuardianEmail.checked = checkbox.checked
      useGuardianEmail.dispatchEvent(new Event('change', { bubbles: true }))
    }

    if (checkbox.checked) {
      this._setCommunicationPreference('letter')
    }

    this.updateFeedback()
    this.updateDeliveryFeedback()
  }

  _selectLetterDelivery() {
    this._setCommunicationPreference('letter')
  }

  _setCommunicationPreference(value) {
    const radioNames = [
      'constituent[communication_preference]',
      'guardian_attributes[communication_preference]'
    ]

    radioNames.forEach((name) => {
      const radio = this.element.querySelector(`input[name="${name}"][value="${value}"]`)
      if (radio) {
        radio.checked = true
      }
    })

    const hiddenField = this.element.querySelector('input[type="hidden"][name="constituent[communication_preference]"]')
    if (hiddenField) hiddenField.value = value

    this.updateDeliveryFeedback()
  }

  _addressOnlyContact() {
    return this._noEmailChecked() && this._noPhoneChecked()
  }

  _toggleRequiredLabel(wrapper, required) {
    const label = wrapper?.querySelector('label')
    if (!label) return

    label.classList.toggle('required-label', required)
  }

  _shouldUseLetterDelivery() {
    if (this._noEmailChecked()) return true

    const emailInput = this._emailInput()
    if (!emailInput) return true

    return emailInput.disabled || !emailInput.value?.trim()
  }

  _phoneTypeRadioNames() {
    return ['constituent[phone_type]', 'guardian_attributes[phone_type]']
  }

  _activePhoneTypeRadioName() {
    return this._phoneTypeRadioNames().find((name) => this.element.querySelector(`input[name="${name}"]`))
  }

  _applyNoPhoneContactType() {
    const phoneTypeValue = this._shouldUseLetterDelivery() ? 'letter' : 'email'
    const radioName = this._activePhoneTypeRadioName()
    if (!radioName) return

    this.element.querySelectorAll(`input[name="${radioName}"]`).forEach((radio) => {
      const selected = radio.value === phoneTypeValue
      radio.checked = selected
      radio.disabled = !selected
    })
  }

  _restorePhoneTypeSelection() {
    const radioName = this._activePhoneTypeRadioName()
    if (!radioName) return

    this.element.querySelectorAll(`input[name="${radioName}"]`).forEach((radio) => {
      radio.disabled = false
    })

    const checked = this.element.querySelector(`input[name="${radioName}"]:checked`)
    if (checked) return

    const voiceRadio = this.element.querySelector(`input[name="${radioName}"][value="voice"]`)
    if (voiceRadio) voiceRadio.checked = true
  }

  _setupNoContactCheckboxListeners() {
    this.element.addEventListener('change', this._boundNoContactCheckboxEvent)
    this.element.addEventListener('click', this._boundNoContactCheckboxEvent)
  }

  _teardownNoContactCheckboxListeners() {
    this.element.removeEventListener('change', this._boundNoContactCheckboxEvent)
    this.element.removeEventListener('click', this._boundNoContactCheckboxEvent)
  }

  _handleNoContactCheckboxEvent(event) {
    const checkbox = this._resolveNoContactCheckbox(event.target)
    if (!checkbox) return

    const applyToggle = () => {
      if (this._isNoEmailCheckbox(checkbox)) {
        this.toggleEmailField({ target: checkbox })
      } else if (this._isNoPhoneCheckbox(checkbox)) {
        this.togglePhoneField({ target: checkbox })
      }
    }

    if (event.type === 'click') {
      requestAnimationFrame(applyToggle)
      return
    }

    applyToggle()
  }

  _resolveNoContactCheckbox(target) {
    if (!(target instanceof Element)) return null

    if (target.matches('input[type="checkbox"]') && this._isNoContactCheckboxName(target.name)) {
      return target
    }

    const label = target.closest('label')
    if (!label || !this.element.contains(label)) return null

    return label.querySelector('input[type="checkbox"][name="no_email_address"], input[type="checkbox"][name="no_phone_number"], input[type="checkbox"][name="guardian_no_email_address"], input[type="checkbox"][name="guardian_no_phone_number"]')
  }

  _isNoContactCheckboxName(name) {
    return ['no_email_address', 'no_phone_number', 'guardian_no_email_address', 'guardian_no_phone_number'].includes(name)
  }

  _isNoEmailCheckbox(checkbox) {
    return checkbox.name === 'no_email_address' || checkbox.name === 'guardian_no_email_address'
  }

  _isNoPhoneCheckbox(checkbox) {
    return checkbox.name === 'no_phone_number' || checkbox.name === 'guardian_no_phone_number'
  }

  _suppressContactField(field) {
    field.disabled = true
    field.dataset.contactFeedbackSuppressed = 'true'
  }

  _restoreContactField(field) {
    field.disabled = false
    delete field.dataset.contactFeedbackSuppressed
  }

  // Outer form sections call this method after they re-enable fields.
  resyncNoContactState() {
    this._syncNoContactCheckboxState()
    this.updateFeedback()
    this.updateDeliveryFeedback()
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
    
    const addressTargets = ['address1', 'address2', 'city', 'state', 'zipCode']
    addressTargets.forEach(targetName => {
      const target = this[`${targetName}Target`]
      if (target) {
        target.removeEventListener("input", this._boundUpdateDeliveryFeedback)
        target.removeEventListener("change", this._boundUpdateDeliveryFeedback)
      }
    })
  }

  updateFeedback() {
    if (!this.hasFeedbackTarget) return

    if (this._addressOnlyContact()) {
      setVisible(this.feedbackTarget, false)
      return
    }
    
    const selectedMethod = this._getSelectedContactMethod()
    if (!selectedMethod) {
      setVisible(this.feedbackTarget, false)
      return
    }
    
    const feedback = this._buildContactFeedback(selectedMethod)
    
    if (feedback) {
      this.feedbackTarget.replaceChildren(feedback.content)
      this.feedbackTarget.className = feedback.className
      setVisible(this.feedbackTarget, true)
      // The markup owns the live-region attributes.
    } else {
      setVisible(this.feedbackTarget, false)
    }
  }

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
      deliveryFeedback.replaceChildren(feedback.content)
      deliveryFeedback.className = feedback.className
      setVisible(deliveryFeedback, true)
      // The markup owns the live-region attributes.
    } else {
      setVisible(deliveryFeedback, false)
    }
  }

  /**
   * @returns {string|null} The selected contact method value
   */
  _getSelectedContactMethod() {
    const radioNames = [
      'constituent[phone_type]',
      'guardian_attributes[phone_type]',
      'contact_method'
    ]
    
    for (const name of radioNames) {
      const checked = this.element.querySelector(`input[name="${name}"]:checked`)
      if (checked) return checked.value
    }
    
    if (this.hasContactMethodTarget) {
      const checked = this.contactMethodTargets.find(r => r.checked)
      return checked?.value || null
    }
    
    return null
  }

  /**
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
   * @param {string} method The preferred contact method (voice, text, videophone, email, letter)
   * @returns {Object|null} DOM content and className, or null if no feedback
   */
  _buildContactFeedback(method) {
    const phoneInput = this._phoneInput()
    const emailInput = this._emailInput()
    const phone = phoneInput ? this._formatPhone(phoneInput.value) : null
    const email = emailInput ? emailInput.value : null
    
    const baseClassName = "mt-2 p-3 rounded-md text-sm font-medium flex items-center gap-2"
    const successClassName = `${baseClassName} bg-teal-50 text-teal-800 border border-teal-200`
    const warningClassName = `${baseClassName} bg-warning-50 text-warning-800 border border-warning-200`
    
    const success = (message, value = null) => this._buildFeedback(message, successClassName, { icon: 'check', value })
    const warning = message => this._buildFeedback(message, warningClassName)
    
    switch (method) {
      case 'voice':
      case 'text':
      case 'videophone':
        if (this._noPhoneChecked()) {
          return success(this.mailMessageValue)
        }
        if (phone) {
          const message = { voice: this.callMessageValue, text: this.textMessageValue, videophone: this.videophoneMessageValue }[method]
          return success(message, phone)
        }
        if (this._usesGuardianPhonePath()) {
          return success('We will use the guardian phone path.')
        }
        return warning(method === 'videophone' ? 'Please enter your videophone number above' : 'Please enter a phone number above')
        
      case 'email':
        if (this._noEmailChecked()) {
          return success(this.mailMessageValue)
        }
        if (email) {
          return success(this.emailMessageValue, email)
        }
        return warning('Please enter an email address above')
        
      case 'letter':
        return success(this.mailMessageValue)

      default:
        return null
    }
  }

  _usesGuardianPhonePath() {
    return this.element.querySelector('#use_guardian_phone_checkbox')?.checked === true
  }

  /**
   * @param {string} method The delivery method (email or letter/mail)
   * @returns {Object|null} DOM content and className, or null if no feedback
   */
  _buildDeliveryFeedback(method) {
    const emailInput = this._emailInput()
    const email = emailInput ? emailInput.value : null
    const addressLines = this._buildAddressLines()
    
    const baseClassName = "mt-2 p-3 rounded-md text-sm font-medium flex items-start gap-2"
    const successClassName = `${baseClassName} bg-primary-50 text-primary-800 border border-primary-200`
    const warningClassName = `${baseClassName} bg-warning-50 text-warning-800 border border-warning-200`
    
    const mailFeedback = () => this._buildFeedback(this.deliveryMailMessageValue, successClassName, { icon: 'mail', addressLines })
    const warning = message => this._buildFeedback(message, warningClassName)
    
    switch (method) {
      case 'email':
        if (this._noEmailChecked() && addressLines) return mailFeedback()
        if (email) {
          return this._buildFeedback(this.deliveryEmailMessageValue, successClassName, { icon: 'mail', value: email })
        }
        return warning('Please enter an email address to receive official documents')
        
      case 'letter':
      case 'mail':
        if (addressLines) return mailFeedback()
        return warning('Please enter your address above to receive official documents by mail')
        
      default:
        return null
    }
  }

  _buildFeedback(message, className, { icon = null, value = null, addressLines = null } = {}) {
    const content = document.createDocumentFragment()
    if (icon) content.appendChild(this._feedbackIcon(icon))

    const body = document.createElement(addressLines ? 'div' : 'span')
    if (addressLines) {
      const heading = document.createElement('div')
      heading.className = 'mb-1'
      heading.textContent = `${message}:`
      const address = document.createElement('strong')
      address.className = 'block'
      addressLines.forEach((line, index) => {
        if (index) address.appendChild(document.createElement('br'))
        address.appendChild(document.createTextNode(line))
      })
      body.append(heading, address)
    } else {
      body.textContent = message
      if (value) {
        const detail = document.createElement('strong')
        detail.textContent = value
        body.append(' ', detail)
      }
    }
    content.appendChild(body)
    return { content, className }
  }

  _feedbackIcon(kind) {
    const namespace = 'http://www.w3.org/2000/svg'
    const icon = document.createElementNS(namespace, 'svg')
    icon.setAttribute('class', `w-5 h-5 flex-shrink-0${kind === 'mail' ? ' mt-0.5' : ''}`)
    icon.setAttribute('fill', 'currentColor')
    icon.setAttribute('viewBox', '0 0 20 20')
    icon.setAttribute('aria-hidden', 'true')
    const paths = kind === 'mail' ? [
      'M2.003 5.884L10 9.882l7.997-3.998A2 2 0 0016 4H4a2 2 0 00-1.997 1.884z',
      'M18 8.118l-8 4-8-4V14a2 2 0 002 2h12a2 2 0 002-2V8.118z'
    ] : ['M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z']
    paths.forEach(data => {
      const path = document.createElementNS(namespace, 'path')
      path.setAttribute('d', data)
      if (kind === 'check') {
        path.setAttribute('fill-rule', 'evenodd')
        path.setAttribute('clip-rule', 'evenodd')
      }
      icon.appendChild(path)
    })
    return icon
  }

  /**
   * @returns {string[]|null} Address lines, or null if required fields are empty
   */
  _buildAddressLines() {
    const address1 = this.hasAddress1Target ? this.address1Target.value.trim() : ''
    const address2 = this.hasAddress2Target ? this.address2Target.value.trim() : ''
    const city = this.hasCityTarget ? this.cityTarget.value.trim() : ''
    const state = this.hasStateTarget ? this.stateTarget.value.trim() : ''
    const zipCode = this.hasZipCodeTarget ? this.zipCodeTarget.value.trim() : ''
    
    if (!address1 || !city || !state || !zipCode) {
      return null
    }
    
    const lines = []
    if (address2) {
      lines.push(`${address1}, ${address2}`)
    } else {
      lines.push(address1)
    }
    lines.push(`${city}, ${state} ${zipCode}`)
    
    return lines
  }

  /**
   * @param {string} phone Raw phone number
   * @returns {string|null} Formatted US phone, original input for other formats, or null if blank
   */
  _formatPhone(phone) {
    if (!phone) return null
    
    const digits = phone.replace(/\D/g, '')
    
    if (digits.length === 10) {
      return `${digits.slice(0, 3)}-${digits.slice(3, 6)}-${digits.slice(6)}`
    }
    
    if (digits.length === 11 && digits.startsWith('1')) {
      const local = digits.slice(1)
      return `${local.slice(0, 3)}-${local.slice(3, 6)}-${local.slice(6)}`
    }
    
    // Preserve other formats for display.
    return phone.trim() || null
  }
}
