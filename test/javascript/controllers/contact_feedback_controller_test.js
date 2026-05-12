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
})
