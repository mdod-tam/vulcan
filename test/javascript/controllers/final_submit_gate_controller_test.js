import FinalSubmitGateController from "controllers/forms/final_submit_gate_controller"

describe("FinalSubmitGateController", () => {
  let controller
  let form
  let submitButton
  let status

  beforeEach(() => {
    document.body.innerHTML = `
      <form>
        <input type="checkbox" name="application[self_certify_disability]" required>
        <input type="checkbox" name="application[terms_accepted]" required>
        <input type="text" name="application[medical_provider_attributes][name]" required>
        <input type="tel" name="application[medical_provider_attributes][phone]" required>
        <input type="email" name="application[medical_provider_attributes][email]" required>
        <input type="file" name="application[income_proof]" required>
        <fieldset data-requires-one-checkbox="true">
          <input type="checkbox" name="application[hearing_disability]">
          <input type="checkbox" name="application[vision_disability]">
        </fieldset>
        <button type="submit" data-final-submit-gate-target="submitButton">Submit</button>
        <button type="submit" name="save_draft">Save Draft</button>
        <p data-final-submit-gate-target="status"></p>
      </form>
    `

    form = document.querySelector("form")
    submitButton = document.querySelector("[data-final-submit-gate-target='submitButton']")
    status = document.querySelector("[data-final-submit-gate-target='status']")
    controller = new FinalSubmitGateController()

    Object.defineProperty(controller, "element", {
      value: form,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "submitButtonTargets", {
      value: [submitButton],
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasStatusTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "statusTarget", {
      value: status,
      writable: false,
      configurable: true
    })
    // Value getters are normally blessed onto the prototype by Stimulus's Application
    // registration, which this raw `new Controller()` instantiation bypasses -- stub
    // them the same way the target properties above are stubbed.
    Object.defineProperty(controller, "incompleteMessageValue", {
      value: "Complete all required confirmations before submitting.",
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "readyMessageValue", {
      value: "Application is ready to submit.",
      writable: false,
      configurable: true
    })

    controller.elementIsVisible = () => true
    controller._incomeExceedsThreshold = false
  })

  afterEach(() => {
    document.body.innerHTML = ""
  })

  function attachRequiredFile() {
    const fileInput = document.querySelector('input[name="application[income_proof]"]')
    Object.defineProperty(fileInput, "files", {
      value: [new File(["proof"], "proof.pdf", { type: "application/pdf" })],
      configurable: true
    })
  }

  test("requires portal self-certification and disability group before final submit", () => {
    controller.update()

    expect(submitButton.disabled).toBe(true)
    expect(status.textContent).toBe("Complete all required confirmations before submitting.")

    document.querySelector('input[name="application[terms_accepted]"]').checked = true
    document.querySelector('input[name="application[hearing_disability]"]').checked = true
    document.querySelector('input[name="application[medical_provider_attributes][name]"]').value = "Dr. Test"
    document.querySelector('input[name="application[medical_provider_attributes][phone]"]').value = "2025551234"
    document.querySelector('input[name="application[medical_provider_attributes][email]"]').value = "doctor@example.com"
    attachRequiredFile()
    controller.update()

    expect(submitButton.disabled).toBe(true)

    document.querySelector('input[name="application[self_certify_disability]"]').checked = true
    controller.update()

    expect(submitButton.disabled).toBe(false)
    expect(status.textContent).toBe("Application is ready to submit.")
  })

  test("requires visible required fields before final submit", () => {
    document.querySelector('input[name="application[self_certify_disability]"]').checked = true
    document.querySelector('input[name="application[terms_accepted]"]').checked = true
    document.querySelector('input[name="application[hearing_disability]"]').checked = true

    controller.update()

    expect(submitButton.disabled).toBe(true)

    document.querySelector('input[name="application[medical_provider_attributes][name]"]').value = "Dr. Test"
    document.querySelector('input[name="application[medical_provider_attributes][phone]"]').value = "2025551234"
    document.querySelector('input[name="application[medical_provider_attributes][email]"]').value = "doctor@example.com"
    attachRequiredFile()
    controller.update()

    expect(submitButton.disabled).toBe(false)
  })

  test("requires visible required file fields before final submit", () => {
    document.querySelector('input[name="application[self_certify_disability]"]').checked = true
    document.querySelector('input[name="application[terms_accepted]"]').checked = true
    document.querySelector('input[name="application[hearing_disability]"]').checked = true
    document.querySelector('input[name="application[medical_provider_attributes][name]"]').value = "Dr. Test"
    document.querySelector('input[name="application[medical_provider_attributes][phone]"]').value = "2025551234"
    document.querySelector('input[name="application[medical_provider_attributes][email]"]').value = "doctor@example.com"

    controller.update()

    expect(submitButton.disabled).toBe(true)

    attachRequiredFile()
    controller.update()

    expect(submitButton.disabled).toBe(false)
  })

  test("income validation event remains part of final submit gate", () => {
    document.querySelector('input[name="application[self_certify_disability]"]').checked = true
    document.querySelector('input[name="application[terms_accepted]"]').checked = true
    document.querySelector('input[name="application[hearing_disability]"]').checked = true
    document.querySelector('input[name="application[medical_provider_attributes][name]"]').value = "Dr. Test"
    document.querySelector('input[name="application[medical_provider_attributes][phone]"]').value = "2025551234"
    document.querySelector('input[name="application[medical_provider_attributes][email]"]').value = "doctor@example.com"
    attachRequiredFile()

    controller.handleIncomeValidation({ detail: { exceedsThreshold: true } })
    expect(submitButton.disabled).toBe(true)

    controller.handleIncomeValidation({ detail: { exceedsThreshold: false } })
    expect(submitButton.disabled).toBe(false)
  })

  test("status messages are configurable per form via values", () => {
    Object.defineProperty(controller, "incompleteMessageValue", {
      value: "Choose a canonical record before merging.",
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "readyMessageValue", {
      value: "Ready to merge.",
      writable: false,
      configurable: true
    })

    controller.update()
    expect(status.textContent).toBe("Choose a canonical record before merging.")

    document.querySelector('input[name="application[self_certify_disability]"]').checked = true
    document.querySelector('input[name="application[terms_accepted]"]').checked = true
    document.querySelector('input[name="application[hearing_disability]"]').checked = true
    document.querySelector('input[name="application[medical_provider_attributes][name]"]').value = "Dr. Test"
    document.querySelector('input[name="application[medical_provider_attributes][phone]"]').value = "2025551234"
    document.querySelector('input[name="application[medical_provider_attributes][email]"]').value = "doctor@example.com"
    attachRequiredFile()
    controller.update()

    expect(status.textContent).toBe("Ready to merge.")
  })

  test("a form with a status target that forgets to declare message values renders blank status text", () => {
    // Documents an intentional tradeoff: incompleteMessage/readyMessage have no
    // Stimulus-level default (see the controller's static values comment), so a form
    // that adds a status target without declaring its own copy gets blank text rather
    // than generic wording borrowed from an unrelated form. Real Stimulus resolves an
    // undeclared String value to "", which this simulates.
    Object.defineProperty(controller, "incompleteMessageValue", {
      value: "",
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "readyMessageValue", {
      value: "",
      writable: false,
      configurable: true
    })

    controller.update()
    expect(status.textContent).toBe("")
  })
})
