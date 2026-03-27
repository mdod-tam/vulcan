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
})
