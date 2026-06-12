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
})
