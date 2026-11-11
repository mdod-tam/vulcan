import ContactFeedbackController from "../../../app/javascript/controllers/forms/contact_feedback_controller"

describe("ContactFeedbackController", () => {
  let controller, fixture

  beforeEach(() => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <input id="use_guardian_phone_checkbox" type="checkbox" />
        <input id="dependent_phone" type="tel" value="" />
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()

    Object.defineProperty(controller, 'element', {
      value: fixture,
      configurable: true
    })
    Object.defineProperty(controller, 'phoneTarget', {
      value: fixture.querySelector('#dependent_phone'),
      configurable: true
    })
    Object.defineProperty(controller, 'hasPhoneTarget', {
      value: true,
      configurable: true
    })
    Object.defineProperty(controller, 'hasEmailTarget', {
      value: false,
      configurable: true
    })
  })

  afterEach(() => {
    document.body.innerHTML = ""
  })

  describe("contact text rendering", () => {
    const payload = '<em data-contact-injection="true">Contact & address</em>'

    beforeEach(() => {
      fixture.innerHTML = `
        <input data-contact-feedback-target="phone" />
        <input data-contact-feedback-target="email" />
        <input data-contact-feedback-target="address1" value="123 Main Street" />
        <input data-contact-feedback-target="address2" value="Apt 4" />
        <input data-contact-feedback-target="city" value="Baltimore" />
        <input data-contact-feedback-target="state" value="MD" />
        <input data-contact-feedback-target="zipCode" value="21201" />
        <input type="checkbox" name="no_email_address" />
        <input type="radio" name="contact_method" value="email" checked />
        <input type="radio" name="delivery_method" value="letter" checked />
        <div data-contact-feedback-target="feedback" aria-live="polite"></div>
        <div data-contact-feedback-target="deliveryFeedback" aria-live="polite"></div>
      `
      for (const name of ['phone', 'email', 'address1', 'address2', 'city', 'state', 'zipCode', 'feedback']) {
        Object.defineProperty(controller, `${name}Target`, {
          value: fixture.querySelector(`[data-contact-feedback-target="${name}"]`), configurable: true
        })
        Object.defineProperty(controller, `has${name[0].toUpperCase()}${name.slice(1)}Target`, {
          value: true, configurable: true
        })
      }
      for (const name of ['call', 'text', 'videophone', 'email', 'mail', 'deliveryEmail', 'deliveryMail']) {
        Object.defineProperty(controller, `${name}MessageValue`, {
          value: `${name} message`, configurable: true
        })
      }
    })

    function assertLiteralText(element, value) {
      expect(element).toHaveTextContent(value)
      expect(element.querySelector('[data-contact-injection], em, img, script')).toBeNull()
      expect(element.querySelector('svg[aria-hidden="true"]')).not.toBeNull()
      expect(element.getAttribute('aria-live')).toBe('polite')
    }

    it.each(['address1', 'address2', 'city', 'state', 'zipCode'])(
      "renders %s as literal text while preserving address line breaks", name => {
        controller[`${name}Target`].value = payload

        controller.updateDeliveryFeedback()

        const feedback = fixture.querySelector('[data-contact-feedback-target="deliveryFeedback"]')
        assertLiteralText(feedback, payload)
        expect(feedback.querySelectorAll('strong br')).toHaveLength(1)
      }
    )

    it.each(['letter', 'mail', 'email'])("keeps address text literal for %s delivery", method => {
      fixture.querySelector('[name="delivery_method"]').value = method
      fixture.querySelector('[name="no_email_address"]').checked = method === 'email'
      controller.address1Target.value = payload

      controller.updateDeliveryFeedback()

      assertLiteralText(fixture.querySelector('[data-contact-feedback-target="deliveryFeedback"]'), payload)
    })

    it.each(['voice', 'text', 'videophone'])("renders raw %s phone text literally", method => {
      fixture.querySelector('[name="contact_method"]').value = method
      controller.phoneTarget.value = payload

      controller.updateFeedback()

      assertLiteralText(controller.feedbackTarget, payload)
    })

    it("renders email text literally in both contact and delivery feedback", () => {
      controller.emailTarget.value = payload
      fixture.querySelector('[name="delivery_method"]').value = 'email'

      controller.updateFeedback()
      controller.updateDeliveryFeedback()

      assertLiteralText(controller.feedbackTarget, payload)
      assertLiteralText(fixture.querySelector('[data-contact-feedback-target="deliveryFeedback"]'), payload)
    })

    it("treats configured feedback messages as text", () => {
      Object.defineProperty(controller, 'emailMessageValue', { value: payload, configurable: true })
      Object.defineProperty(controller, 'deliveryMailMessageValue', { value: payload, configurable: true })
      controller.emailTarget.value = 'person@example.com'

      controller.updateFeedback()
      controller.updateDeliveryFeedback()

      assertLiteralText(controller.feedbackTarget, payload)
      assertLiteralText(fixture.querySelector('[data-contact-feedback-target="deliveryFeedback"]'), payload)
    })
  })

  it("does not ask for dependent phone when guardian phone path is selected", () => {
    fixture.querySelector('#use_guardian_phone_checkbox').checked = true

    const feedback = controller._buildContactFeedback('text')

    expect(feedback.content.textContent).toContain('guardian phone path')
    expect(feedback.content.textContent).not.toContain('Please enter a phone number above')
    expect(feedback.className).toContain('bg-teal-50')
  })

  it("asks for phone when no phone path is available", () => {
    const feedback = controller._buildContactFeedback('text')

    expect(feedback.content.textContent).toContain('Please enter a phone number above')
    expect(feedback.className).toContain('bg-warning-50')
  })

  it("syncNoContactCheckboxState applies toggle when checkbox is pre-checked", () => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <input type="checkbox" name="no_phone_number" checked />
        <div data-contact-feedback-target="phoneWrapper">
          <input data-contact-feedback-target="phone" id="phone" type="tel" value="4105550100" required aria-required="true" />
        </div>
        <fieldset data-contact-feedback-target="phoneTypeFieldset"></fieldset>
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()
    Object.defineProperty(controller, 'element', { value: fixture, configurable: true })
    controller.connect()

    const phoneInput = fixture.querySelector('#phone')
    const phoneWrapper = fixture.querySelector('[data-contact-feedback-target="phoneWrapper"]')
    expect(phoneWrapper.classList.contains('hidden')).toBe(true)
    expect(phoneInput.disabled).toBe(true)
  })

  it("shows mail feedback when no phone checkbox is checked", () => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <input type="checkbox" name="no_phone_number" checked />
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()
    Object.defineProperty(controller, 'element', { value: fixture, configurable: true })

    const feedback = controller._buildContactFeedback('voice')
    expect(feedback.content.textContent).not.toContain('Please enter a phone number above')
    expect(feedback.className).toContain('bg-teal-50')
  })

  it("togglePhoneField hides phone input and fieldset when checked", () => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <div data-contact-feedback-target="phoneWrapper">
          <input data-contact-feedback-target="phone" id="phone" type="tel" value="4105550100" required aria-required="true" />
        </div>
        <fieldset data-contact-feedback-target="phoneTypeFieldset"></fieldset>
        <input type="checkbox" id="no_phone" />
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()
    Object.defineProperty(controller, 'element', { value: fixture, configurable: true })
    Object.defineProperty(controller, 'phoneTarget', { value: fixture.querySelector('[data-contact-feedback-target="phone"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'phoneWrapperTarget', { value: fixture.querySelector('[data-contact-feedback-target="phoneWrapper"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneWrapperTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'phoneTypeFieldsetTarget', { value: fixture.querySelector('[data-contact-feedback-target="phoneTypeFieldset"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneTypeFieldsetTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'hasEmailTarget', { value: false, configurable: true })

    const checkbox = fixture.querySelector('#no_phone')
    checkbox.checked = true
    controller.togglePhoneField({ target: checkbox })

    const phoneInput = fixture.querySelector('#phone')
    const phoneWrapper = fixture.querySelector('[data-contact-feedback-target="phoneWrapper"]')
    expect(phoneWrapper.classList.contains('hidden')).toBe(true)
    expect(phoneInput.disabled).toBe(true)
    expect(phoneInput.required).toBe(false)
    expect(fixture.querySelector('[data-contact-feedback-target="phoneTypeFieldset"]').classList.contains('hidden')).toBe(true)
  })

  it("toggleEmailField hides email input when checked", () => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <div data-contact-feedback-target="emailWrapper">
          <label class="required-label">Email</label>
          <input data-contact-feedback-target="email" id="email" type="email" value="user@example.com" required aria-required="true" />
        </div>
        <input type="hidden" name="constituent[communication_preference]" value="email" />
        <input type="checkbox" id="no_email" />
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()
    Object.defineProperty(controller, 'element', { value: fixture, configurable: true })

    const checkbox = fixture.querySelector('#no_email')
    checkbox.checked = true
    controller.toggleEmailField({ target: checkbox })

    const emailInput = fixture.querySelector('#email')
    const emailWrapper = fixture.querySelector('[data-contact-feedback-target="emailWrapper"]')
    expect(emailWrapper.classList.contains('hidden')).toBe(true)
    expect(emailInput.disabled).toBe(true)
    expect(emailInput.required).toBe(false)
    expect(fixture.querySelector('input[name="constituent[communication_preference]"]').value).toBe('letter')
  })

  it("address-only contact hides feedback and both contact wrappers", () => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <input type="checkbox" name="no_email_address" checked />
        <input type="checkbox" name="no_phone_number" checked />
        <div data-contact-feedback-target="emailWrapper" class="hidden">
          <input data-contact-feedback-target="email" type="email" disabled />
        </div>
        <div data-contact-feedback-target="phoneWrapper" class="hidden">
          <input data-contact-feedback-target="phone" type="tel" disabled />
        </div>
        <fieldset data-contact-feedback-target="phoneTypeFieldset" class="hidden">
          <input type="radio" name="constituent[phone_type]" value="letter" checked />
        </fieldset>
        <div data-contact-feedback-target="feedback"></div>
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()
    Object.defineProperty(controller, 'element', { value: fixture, configurable: true })
    Object.defineProperty(controller, 'feedbackTarget', { value: fixture.querySelector('[data-contact-feedback-target="feedback"]'), configurable: true })
    Object.defineProperty(controller, 'hasFeedbackTarget', { value: true, configurable: true })

    controller.updateFeedback()

    expect(fixture.querySelector('[data-contact-feedback-target="feedback"]').classList.contains('hidden')).toBe(true)
    expect(controller._addressOnlyContact()).toBe(true)
  })

  it("clicking no-contact label toggles email field after animation frame", () => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <label class="flex items-center gap-2 cursor-pointer">
          <input type="checkbox" name="no_email_address" value="1" id="no_email" />
          <span>Applicant does not have an email address</span>
        </label>
        <div data-contact-feedback-target="emailWrapper">
          <label class="required-label">Email</label>
          <input data-contact-feedback-target="email" id="email" type="email" value="user@example.com" required aria-required="true" />
        </div>
        <input type="hidden" name="constituent[communication_preference]" value="email" />
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()
    Object.defineProperty(controller, 'element', { value: fixture, configurable: true })
    controller.connect()

    const checkbox = fixture.querySelector('#no_email')
    const label = fixture.querySelector('label.flex')
    checkbox.checked = true
    controller._handleNoContactCheckboxEvent({ type: 'click', target: label.querySelector('span') })

    return new Promise((resolve) => {
      requestAnimationFrame(() => {
        const emailWrapper = fixture.querySelector('[data-contact-feedback-target="emailWrapper"]')
        expect(emailWrapper.classList.contains('hidden')).toBe(true)
        expect(emailWrapper.style.display).toBe('none')
        resolve()
      })
    })
  })

  it("togglePhoneField keeps email delivery when email is present", () => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <div data-contact-feedback-target="emailWrapper">
          <input data-contact-feedback-target="email" id="email" type="email" value="user@example.com" required />
        </div>
        <div data-contact-feedback-target="phoneWrapper">
          <input data-contact-feedback-target="phone" id="phone" type="tel" value="4105550100" required />
        </div>
        <fieldset data-contact-feedback-target="phoneTypeFieldset"></fieldset>
        <input type="radio" name="constituent[communication_preference]" value="email" checked />
        <input type="radio" name="constituent[communication_preference]" value="letter" />
        <input type="checkbox" id="no_phone" />
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()
    Object.defineProperty(controller, 'element', { value: fixture, configurable: true })
    Object.defineProperty(controller, 'emailTarget', { value: fixture.querySelector('[data-contact-feedback-target="email"]'), configurable: true })
    Object.defineProperty(controller, 'hasEmailTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'phoneTarget', { value: fixture.querySelector('[data-contact-feedback-target="phone"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'phoneWrapperTarget', { value: fixture.querySelector('[data-contact-feedback-target="phoneWrapper"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneWrapperTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'phoneTypeFieldsetTarget', { value: fixture.querySelector('[data-contact-feedback-target="phoneTypeFieldset"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneTypeFieldsetTarget', { value: true, configurable: true })

    const checkbox = fixture.querySelector('#no_phone')
    checkbox.checked = true
    controller.togglePhoneField({ target: checkbox })

    const emailDelivery = fixture.querySelector('input[name="constituent[communication_preference]"][value="email"]')
    const letterDelivery = fixture.querySelector('input[name="constituent[communication_preference]"][value="letter"]')
    expect(emailDelivery.checked).toBe(true)
    expect(letterDelivery.checked).toBe(false)
  })

  it("togglePhoneField clears voice phone_type and selects letter when address-only", () => {
    document.body.innerHTML = `
      <div id="contact-feedback">
        <input type="checkbox" name="no_email_address" checked />
        <div data-contact-feedback-target="phoneWrapper">
          <input data-contact-feedback-target="phone" id="phone" type="tel" value="4105550100" required />
        </div>
        <fieldset data-contact-feedback-target="phoneTypeFieldset">
          <input type="radio" name="guardian_attributes[phone_type]" value="voice" checked />
          <input type="radio" name="guardian_attributes[phone_type]" value="text" />
          <input type="radio" name="guardian_attributes[phone_type]" value="letter" />
        </fieldset>
        <input type="checkbox" id="no_phone" />
      </div>
    `

    fixture = document.querySelector('#contact-feedback')
    controller = new ContactFeedbackController()
    Object.defineProperty(controller, 'element', { value: fixture, configurable: true })
    Object.defineProperty(controller, 'phoneTarget', { value: fixture.querySelector('[data-contact-feedback-target="phone"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'phoneWrapperTarget', { value: fixture.querySelector('[data-contact-feedback-target="phoneWrapper"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneWrapperTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'phoneTypeFieldsetTarget', { value: fixture.querySelector('[data-contact-feedback-target="phoneTypeFieldset"]'), configurable: true })
    Object.defineProperty(controller, 'hasPhoneTypeFieldsetTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'hasEmailTarget', { value: false, configurable: true })

    const checkbox = fixture.querySelector('#no_phone')
    checkbox.checked = true
    controller.togglePhoneField({ target: checkbox })

    const voiceRadio = fixture.querySelector('input[value="voice"]')
    const letterRadio = fixture.querySelector('input[value="letter"]')
    expect(voiceRadio.checked).toBe(false)
    expect(voiceRadio.disabled).toBe(true)
    expect(letterRadio.checked).toBe(true)
    expect(letterRadio.disabled).toBe(false)
  })
})
