import FinalSubmitGateController from "controllers/forms/final_submit_gate_controller"

function mount(formElement) {
  const submitButton = formElement.querySelector("[data-final-submit-gate-target='submitButton']")
  const status = formElement.querySelector("[data-final-submit-gate-target='status']")
  const controller = new FinalSubmitGateController()

  Object.defineProperty(controller, "element", {
    value: formElement,
    writable: false,
    configurable: true
  })
  Object.defineProperty(controller, "submitButtonTargets", {
    value: submitButton ? [submitButton] : [],
    writable: false,
    configurable: true
  })
  Object.defineProperty(controller, "hasStatusTarget", {
    value: Boolean(status),
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
  controller._conditionalRequiredSourceValues = new Map()

  return { controller, submitButton, status }
}

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
        <input type="radio"
               name="contact[phone_user_id]"
               value="1"
               data-final-submit-gate-conditional-required-source="phone-type"
               data-final-submit-gate-required-when-selected="true">
        <input type="radio"
               name="contact[phone_user_id]"
               value="2"
               data-final-submit-gate-conditional-required-source="phone-type"
               data-final-submit-gate-required-when-selected="true">
        <input type="radio"
               name="contact[phone_user_id]"
               value="3"
               data-final-submit-gate-conditional-required-source="phone-type"
               data-final-submit-gate-required-when-selected="false">
        <select name="contact[phone_type]"
                aria-required="false"
                data-final-submit-gate-conditional-required="phone-type">
          <option value=""></option>
          <option value="voice">Voice</option>
          <option value="text">Text</option>
        </select>
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
    ;({ controller, submitButton, status } = mount(form))
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

  function completeEveryRequirement() {
    document.querySelector('input[name="application[self_certify_disability]"]').checked = true
    document.querySelector('input[name="application[terms_accepted]"]').checked = true
    document.querySelector('input[name="application[hearing_disability]"]').checked = true
    document.querySelector('input[name="application[medical_provider_attributes][name]"]').value = "Dr. Test"
    document.querySelector('input[name="application[medical_provider_attributes][phone]"]').value = "2025551234"
    document.querySelector('input[name="application[medical_provider_attributes][email]"]').value = "doctor@example.com"
    attachRequiredFile()
  }

  // A server-set block outranks completeness. Without it the constituent can fill the form
  // perfectly, watch the button enable, submit, and have the server refuse -- discarding the file
  // selections no browser lets the re-render restore.
  test("keeps final submit disabled while a server-set block is present", () => {
    completeEveryRequirement()
    form.dataset.finalSubmitGateBlockedMessage = "Submitting is unavailable while we review this application."

    controller.update()

    expect(submitButton.disabled).toBe(true)
    expect(submitButton.getAttribute("aria-disabled")).toBe("true")
    expect(status.textContent).toBe("Submitting is unavailable while we review this application.")
  })

  test("an empty block message is not a block", () => {
    completeEveryRequirement()
    form.dataset.finalSubmitGateBlockedMessage = ""

    controller.update()

    expect(submitButton.disabled).toBe(false)
    expect(status.textContent).toBe("Application is ready to submit.")
  })

  test("clearing the block restores the ordinary completeness gate", () => {
    form.dataset.finalSubmitGateBlockedMessage = "Submitting is unavailable while we review this application."
    controller.update()
    expect(submitButton.disabled).toBe(true)

    delete form.dataset.finalSubmitGateBlockedMessage
    controller.update()
    // Still disabled, but now for the ordinary reason -- nothing has been filled in yet.
    expect(submitButton.disabled).toBe(true)
    expect(status.textContent).toBe("Complete all required confirmations before submitting.")

    completeEveryRequirement()
    controller.update()

    expect(submitButton.disabled).toBe(false)
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

  test("requires phone type exactly when the selected phone is real", () => {
    const realPhone = document.querySelector('input[name="contact[phone_user_id]"][value="1"]')
    const blankPhone = document.querySelector('input[name="contact[phone_user_id]"][value="3"]')
    const phoneType = document.querySelector('select[name="contact[phone_type]"]')

    realPhone.checked = true
    controller.update()

    expect(phoneType.required).toBe(true)
    expect(phoneType.getAttribute("aria-required")).toBe("true")

    phoneType.value = "voice"
    controller.update()
    expect(phoneType.value).toBe("voice")

    blankPhone.checked = true
    controller.update()

    expect(phoneType.required).toBe(false)
    expect(phoneType.getAttribute("aria-required")).toBe("false")
    expect(phoneType.value).toBe("")
  })

  test("clears phone type when the selected real-phone source changes", () => {
    const firstPhone = document.querySelector('input[name="contact[phone_user_id]"][value="1"]')
    const secondPhone = document.querySelector('input[name="contact[phone_user_id]"][value="2"]')
    const phoneType = document.querySelector('select[name="contact[phone_type]"]')

    firstPhone.checked = true
    controller.update()
    phoneType.value = "text"
    controller.update()

    secondPhone.checked = true
    controller.update()

    expect(phoneType.required).toBe(true)
    expect(phoneType.value).toBe("")
  })

  test("uses form-specific status messages when provided", () => {
    form.dataset.finalSubmitGateIncompleteMessage = "Complete the merge decisions."
    form.dataset.finalSubmitGateReadyMessage = "Merge is ready."

    controller.update()
    expect(status.textContent).toBe("Complete the merge decisions.")
  })

  test("leaves the incomplete message undetailed when the form does not opt in", () => {
    expect(form.dataset.finalSubmitGateIncompleteDetailMessage).toBeUndefined()

    controller.update()

    expect(status.textContent).toBe("Complete all required confirmations before submitting.")
  })
})

// The admin merge form is the only opt-in consumer of the detail template, and the only form
// whose radio groups are wrapped in nested fieldsets. Its own fixture keeps that structure
// explicit rather than inferring group naming from the constituent-portal shape above.
describe("FinalSubmitGateController merge-form decision naming", () => {
  let controller
  let form
  let status

  beforeEach(() => {
    document.body.innerHTML = `
      <form data-final-submit-gate-incomplete-message="Complete every required merge decision before submitting."
            data-final-submit-gate-incomplete-detail-message="Still needed: %{items}."
            data-final-submit-gate-ready-message="Merge form is ready to submit.">
        <fieldset>
          <legend>Canonical record</legend>
          <input type="radio" name="canonical_user_id" value="1" required>
          <input type="radio" name="canonical_user_id" value="2" required>
        </fieldset>
        <fieldset>
          <legend>Contact facts to keep</legend>
          <fieldset>
            <legend>Phone</legend>
            <input type="radio" name="contact[phone_user_id]" value="1" required
                   data-final-submit-gate-conditional-required-source="phone-type"
                   data-final-submit-gate-required-when-selected="true">
            <input type="radio" name="contact[phone_user_id]" value="2" required
                   data-final-submit-gate-conditional-required-source="phone-type"
                   data-final-submit-gate-required-when-selected="false">
          </fieldset>
          <div>
            <label for="merge-phone-type">Phone type</label>
            <select id="merge-phone-type"
                    name="contact[phone_type]"
                    aria-required="false"
                    data-final-submit-gate-conditional-required="phone-type">
              <option value=""></option>
              <option value="voice">Voice</option>
            </select>
          </div>
          <fieldset>
            <legend>Address</legend>
            <input type="radio" name="contact[address_user_id]" value="1" required>
          </fieldset>
        </fieldset>
        <button type="submit" data-final-submit-gate-target="submitButton">Merge</button>
        <p data-final-submit-gate-target="status"></p>
      </form>
    `

    form = document.querySelector("form")
    ;({ controller, status } = mount(form))
  })

  afterEach(() => {
    document.body.innerHTML = ""
  })

  test("names each incomplete radio group by its own nested legend", () => {
    controller.update()

    expect(status.textContent).toBe(
      "Complete every required merge decision before submitting. Still needed: Canonical record, Phone, Address."
    )
  })

  test("names a conditionally required single control by its label, not its enclosing group", () => {
    document.querySelector('input[name="canonical_user_id"][value="1"]').checked = true
    document.querySelector('input[name="contact[phone_user_id]"][value="1"]').checked = true
    document.querySelector('input[name="contact[address_user_id]"][value="1"]').checked = true

    controller.update()

    expect(status.textContent).toBe(
      "Complete every required merge decision before submitting. Still needed: Phone type."
    )
  })

  test("disables phone type when the surviving phone is blank and re-enables it for a real phone", () => {
    const realPhone = document.querySelector('input[name="contact[phone_user_id]"][value="1"]')
    const blankPhone = document.querySelector('input[name="contact[phone_user_id]"][value="2"]')
    const phoneType = document.querySelector('select[name="contact[phone_type]"]')

    blankPhone.checked = true
    controller.update()

    expect(phoneType.disabled).toBe(true)
    expect(phoneType.required).toBe(false)

    blankPhone.checked = false
    realPhone.checked = true
    controller.update()

    expect(phoneType.disabled).toBe(false)
    expect(phoneType.required).toBe(true)
  })

  test("reaches a ready state once every decision is made", () => {
    document.querySelector('input[name="canonical_user_id"][value="1"]').checked = true
    document.querySelector('input[name="contact[phone_user_id]"][value="1"]').checked = true
    document.querySelector('input[name="contact[address_user_id]"][value="1"]').checked = true
    controller.update()

    document.querySelector('select[name="contact[phone_type]"]').value = "voice"
    controller.update()

    expect(status.textContent).toBe("Merge form is ready to submit.")
  })
})
