import { Application } from "@hotwired/stimulus"
import PaperApplicationController from "controllers/forms/paper_application_controller"

describe("PaperApplicationController", () => {
  let application
  let controller
  let element
  let incomeProofInput
  let residencyProofInput
  let incomeProofSignedId
  let residencyProofSignedId
  
  beforeEach(() => {
    // Set up DOM
    document.body.innerHTML = `
      <form data-controller="paper-application">
        <!-- Income proof radio buttons -->
        <input type="radio" id="accept_income_proof" name="income_proof_action" value="accept">
        <input type="radio" id="reject_income_proof" name="income_proof_action" value="reject">
        
        <!-- Residency proof radio buttons -->
        <input type="radio" id="accept_residency_proof" name="residency_proof_action" value="accept">
        <input type="radio" id="reject_residency_proof" name="residency_proof_action" value="reject">
        
        <!-- File inputs -->
        <input type="file" name="income_proof">
        <input type="file" name="residency_proof">
        
        <!-- Hidden signed_id fields -->
        <input type="hidden" name="income_proof_signed_id" value="">
        <input type="hidden" name="residency_proof_signed_id" value="">

        <!-- Existing adult verification controls -->
        <input type="hidden" name="existing_constituent_id" value="">
        <input type="checkbox" name="contact_info_verified" data-adult-picker-target="verificationCheckbox">
        
        <!-- Status text elements -->
        <div id="income_proof_upload">
          <div data-upload-target="statusText">No file selected</div>
        </div>
        <div id="residency_proof_upload">
          <div data-upload-target="statusText">No file selected</div>
        </div>
        
        <!-- Rejection sections -->
        <div id="income_proof_rejection">
          <select name="income_proof_rejection_reason">
            <option value="">Select a reason</option>
            <option value="address_mismatch">Address Mismatch</option>
          </select>
        </div>
        <div id="residency_proof_rejection">
          <select name="residency_proof_rejection_reason">
            <option value="">Select a reason</option>
            <option value="address_mismatch">Address Mismatch</option>
          </select>
        </div>
        
        <!-- Submit button -->
        <button type="submit" data-paper-application-target="submitButton">Submit</button>
      </form>
    `

    // Set up Stimulus controller
    application = Application.start()
    application.register("paper-application", PaperApplicationController)

    element = document.querySelector("[data-controller='paper-application']")
    incomeProofInput = document.querySelector("input[name='income_proof']")
    residencyProofInput = document.querySelector("input[name='residency_proof']")
    incomeProofSignedId = document.querySelector("input[name='income_proof_signed_id']")
    residencyProofSignedId = document.querySelector("input[name='residency_proof_signed_id']")
    
    // Initialize controller
    controller = application.getControllerForElementAndIdentifier(element, "paper-application")
  })

  test("PaperApplicationController connects successfully", () => {
    expect(controller).toBeDefined();
    expect(element).toBeDefined();
  });

  test("inactive adult verification fields do not block submit", () => {
    const directController = new PaperApplicationController()
    const submitButton = document.querySelector("[data-paper-application-target='submitButton']")
    const existingAdultField = document.querySelector("input[name='existing_constituent_id']")
    const verificationCheckbox = document.querySelector("input[name='contact_info_verified']")

    Object.defineProperty(directController, "element", {
      value: element,
      writable: false,
      configurable: true
    })

    Object.defineProperty(directController, "hasSubmitButtonTarget", {
      value: true,
      writable: false,
      configurable: true
    })

    Object.defineProperty(directController, "submitButtonTarget", {
      value: submitButton,
      writable: false,
      configurable: true
    })

    Object.defineProperty(directController, "hasRejectionButtonTarget", {
      value: false,
      writable: false,
      configurable: true
    })

    existingAdultField.value = "42"
    existingAdultField.disabled = true
    verificationCheckbox.checked = false
    verificationCheckbox.disabled = true

    directController.syncAdultVerificationGate()

    expect(submitButton.disabled).toBe(false)
  })

  test("medical provider toggle manages provider and release requirements", () => {
    document.body.innerHTML = `
      <form data-controller="paper-application">
        <fieldset>
          <input
            type="checkbox"
            name="no_medical_provider_information"
            data-action="change->paper-application#toggleMedicalProvider"
          >
          <p class="text-sm">Provider description</p>
          <div class="grid">
            <input type="text" name="application[medical_provider_name]" required>
            <input type="tel" name="application[medical_provider_phone]" required>
            <input type="email" name="application[medical_provider_email]" required>
            <input type="text" name="application[medical_provider_fax]">
          </div>
          <input type="hidden" name="application[medical_release_authorized]" value="0">
          <input type="checkbox" name="application[medical_release_authorized]" value="1" required>
        </fieldset>
      </form>
    `

    const form = document.querySelector("[data-controller='paper-application']")
    const directController = new PaperApplicationController()
    const checkbox = document.querySelector("input[name='no_medical_provider_information']")
    const providerName = document.querySelector("input[name='application[medical_provider_name]']")
    const providerPhone = document.querySelector("input[name='application[medical_provider_phone]']")
    const providerEmail = document.querySelector("input[name='application[medical_provider_email]']")
    const providerFax = document.querySelector("input[name='application[medical_provider_fax]']")
    const hiddenMedicalRelease = document.querySelector("input[type='hidden'][name='application[medical_release_authorized]']")
    const medicalRelease = document.querySelector("input[type='checkbox'][name='application[medical_release_authorized]']")

    Object.defineProperty(directController, "element", {
      value: form,
      writable: false,
      configurable: true
    })

    checkbox.checked = true
    directController.toggleMedicalProvider({ target: checkbox })

    expect(providerName.hasAttribute("required")).toBe(false)
    expect(providerPhone.hasAttribute("required")).toBe(false)
    expect(providerEmail.hasAttribute("required")).toBe(false)
    expect(providerFax.hasAttribute("required")).toBe(false)
    expect(hiddenMedicalRelease.hasAttribute("required")).toBe(false)
    expect(medicalRelease.hasAttribute("required")).toBe(false)
    expect(checkbox.hasAttribute("required")).toBe(false)

    checkbox.checked = false
    providerName.value = "Dr. Test"
    directController.syncMedicalProviderRequirement({ target: providerName })

    expect(providerName.hasAttribute("required")).toBe(true)
    expect(providerPhone.hasAttribute("required")).toBe(true)
    expect(providerEmail.hasAttribute("required")).toBe(true)
    expect(providerFax.hasAttribute("required")).toBe(false)
    expect(hiddenMedicalRelease.hasAttribute("required")).toBe(false)
    expect(medicalRelease.hasAttribute("required")).toBe(true)
    expect(checkbox.hasAttribute("required")).toBe(false)
  })

  test("blank provider info requires the no-provider checkbox instead of provider fields", () => {
    document.body.innerHTML = `
      <form data-controller="paper-application">
        <fieldset>
          <input type="checkbox" name="no_medical_provider_information">
          <p class="text-sm">Provider description</p>
          <div class="grid">
            <input type="text" name="application[medical_provider_name]" required>
            <input type="tel" name="application[medical_provider_phone]" required>
            <input type="email" name="application[medical_provider_email]" required>
            <input type="text" name="application[medical_provider_fax]">
          </div>
          <input type="hidden" name="application[medical_release_authorized]" value="0">
          <input type="checkbox" name="application[medical_release_authorized]" value="1" required>
        </fieldset>
      </form>
    `

    const form = document.querySelector("[data-controller='paper-application']")
    const directController = new PaperApplicationController()
    const checkbox = document.querySelector("input[name='no_medical_provider_information']")
    const providerName = document.querySelector("input[name='application[medical_provider_name]']")
    const providerPhone = document.querySelector("input[name='application[medical_provider_phone]']")
    const providerEmail = document.querySelector("input[name='application[medical_provider_email]']")
    const hiddenMedicalRelease = document.querySelector("input[type='hidden'][name='application[medical_release_authorized]']")
    const medicalRelease = document.querySelector("input[type='checkbox'][name='application[medical_release_authorized]']")

    Object.defineProperty(directController, "element", {
      value: form,
      writable: false,
      configurable: true
    })

    directController.syncMedicalProviderRequirement()

    expect(providerName.hasAttribute("required")).toBe(false)
    expect(providerPhone.hasAttribute("required")).toBe(false)
    expect(providerEmail.hasAttribute("required")).toBe(false)
    expect(hiddenMedicalRelease.hasAttribute("required")).toBe(false)
    expect(medicalRelease.hasAttribute("required")).toBe(false)
    expect(checkbox.hasAttribute("required")).toBe(true)
    expect(checkbox.validationMessage).toBe("Check this box if no certifying professional information was provided.")

    providerName.value = "Dr. Test"
    providerPhone.value = "555-111-2222"
    providerEmail.value = "dr.test@example.com"
    directController.syncMedicalProviderRequirement({ target: providerEmail })

    expect(providerName.hasAttribute("required")).toBe(true)
    expect(providerPhone.hasAttribute("required")).toBe(true)
    expect(providerEmail.hasAttribute("required")).toBe(true)
    expect(hiddenMedicalRelease.hasAttribute("required")).toBe(false)
    expect(medicalRelease.hasAttribute("required")).toBe(true)
    expect(checkbox.hasAttribute("required")).toBe(false)
    expect(checkbox.validationMessage).toBe("")
  })
})
