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

  it("does not ask for dependent phone when guardian phone path is selected", () => {
    fixture.querySelector('#use_guardian_phone_checkbox').checked = true

    const feedback = controller._buildContactFeedback('text')

    expect(feedback.html).toContain('guardian phone path')
    expect(feedback.html).not.toContain('Please enter a phone number above')
    expect(feedback.className).toContain('bg-teal-50')
  })

  it("asks for phone when no phone path is available", () => {
    const feedback = controller._buildContactFeedback('text')

    expect(feedback.html).toContain('Please enter a phone number above')
    expect(feedback.className).toContain('bg-amber-50')
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
    expect(feedback.html).not.toContain('Please enter a phone number above')
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
})
