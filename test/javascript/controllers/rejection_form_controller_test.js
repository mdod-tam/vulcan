import { Application } from "@hotwired/stimulus"
import RejectionFormController from "controllers/forms/rejection_form_controller"

describe("RejectionFormController", () => {
  let application
  let element
  let generalReasons
  let medicalOnlyReasons

  beforeEach(() => {
    // Set up DOM
    document.body.innerHTML = `
      <div data-controller="rejection-form">
        <input type="hidden" id="rejection-proof-type" value="" data-rejection-form-target="proofType">
        <input type="hidden" data-rejection-form-target="reasonCode">
        <textarea data-rejection-form-target="reasonField"></textarea>
        <p data-rejection-form-target="codeStatus"></p>
        <p class="hidden" data-rejection-form-target="languageNotice"></p>
        <p data-rejection-form-target="liveRegion"></p>
        <div class="general-reasons hidden" data-rejection-form-target="generalReasons">
          <button
            data-action="click->rejection-form#selectPredefinedReason"
            data-rejection-form-target="reasonButton"
            data-reason-code="address_mismatch"
            data-reason-text="Address mismatch general text"
            data-proof-types="income,residency">
            Address mismatch
          </button>
        </div>
        <div class="medical-only-reasons hidden" data-rejection-form-target="medicalOnlyReasons">
          <button
            data-action="click->rejection-form#selectPredefinedReason"
            data-rejection-form-target="reasonButton"
            data-reason-code="medical_missing"
            data-reason-text="Medical missing text"
            data-proof-types="medical">
            Medical missing
          </button>
        </div>
        <button data-action="click->rejection-form#handleProofTypeClick" data-proof-type="income">Income Proof</button>
        <button data-action="click->rejection-form#handleProofTypeClick" data-proof-type="residency">Residency Proof</button>
        <button data-action="click->rejection-form#handleProofTypeClick" data-proof-type="medical">Medical Proof</button>
      </div>
    `

    // Set up Stimulus application
    application = Application.start()
    application.register("rejection-form", RejectionFormController)

    element = document.querySelector("[data-controller='rejection-form']")
    generalReasons = document.querySelector(".general-reasons")
    medicalOnlyReasons = document.querySelector(".medical-only-reasons")
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  test("shows general reasons when income proof type is selected", () => {
    const controller = application.getControllerForElementAndIdentifier(element, "rejection-form")
    const proofTypeInput = controller.proofTypeTarget
    
    const incomeButton = document.querySelector("[data-proof-type='income']")
    incomeButton.click()
    
    expect(proofTypeInput.value).toBe("income")
    expect(generalReasons.classList.contains("hidden")).toBe(false)
    expect(medicalOnlyReasons.classList.contains("hidden")).toBe(true)
  })

  test("shows general reasons when residency proof type is selected", () => {
    const controller = application.getControllerForElementAndIdentifier(element, "rejection-form")
    const proofTypeInput = controller.proofTypeTarget
    
    const residencyButton = document.querySelector("[data-proof-type='residency']")
    residencyButton.click()
    
    expect(proofTypeInput.value).toBe("residency")
    expect(generalReasons.classList.contains("hidden")).toBe(false)
    expect(medicalOnlyReasons.classList.contains("hidden")).toBe(true)
  })

  test("initializes with reason groups hidden by default", () => {
    const controller = application.getControllerForElementAndIdentifier(element, "rejection-form")
    // The controller's connect method should handle initial visibility
    expect(generalReasons.classList.contains("hidden")).toBe(true)
    expect(medicalOnlyReasons.classList.contains("hidden")).toBe(true)
  })

  test("updates reason group visibility when proof type changes", () => {
    const controller = application.getControllerForElementAndIdentifier(element, "rejection-form")
    const incomeButton = document.querySelector("[data-proof-type='income']")
    const residencyButton = document.querySelector("[data-proof-type='residency']")
    const medicalButton = document.querySelector("[data-proof-type='medical']")
    
    incomeButton.click()
    expect(generalReasons.classList.contains("hidden")).toBe(false)
    expect(medicalOnlyReasons.classList.contains("hidden")).toBe(true)

    medicalButton.click()
    expect(generalReasons.classList.contains("hidden")).toBe(true)
    expect(medicalOnlyReasons.classList.contains("hidden")).toBe(false)
    
    residencyButton.click()
    expect(generalReasons.classList.contains("hidden")).toBe(false)
    expect(medicalOnlyReasons.classList.contains("hidden")).toBe(true)
  })

  test("selects predefined reason text when button is clicked", () => {
    const controller = application.getControllerForElementAndIdentifier(element, "rejection-form")
    const proofTypeInput = controller.proofTypeTarget
    const reasonField = controller.reasonFieldTarget
    const reasonCodeInput = controller.reasonCodeTarget
    
    const incomeButton = document.querySelector("[data-proof-type='income']")
    incomeButton.click() // Set proofTypeInput.value to "income"
    
    const reasonButton = document.querySelector("[data-reason-code='address_mismatch']")
    
    controller.selectPredefinedReason({ currentTarget: reasonButton })
    expect(reasonField.value).toBe("Address mismatch general text")
    expect(reasonCodeInput.value).toBe("address_mismatch")
    
    const medicalButton = document.querySelector("[data-proof-type='medical']")
    medicalButton.click() // Set proofTypeInput.value to "medical"
    
    const medicalReasonButton = document.querySelector("[data-reason-code='medical_missing']")
    controller.selectPredefinedReason({ currentTarget: medicalReasonButton })
    expect(reasonField.value).toBe("Medical missing text")
    expect(reasonCodeInput.value).toBe("medical_missing")
  })

  test("validates form submission", () => {
    const controller = application.getControllerForElementAndIdentifier(element, "rejection-form")
    const proofTypeInput = controller.proofTypeTarget
    const reasonField = controller.reasonFieldTarget
    
    const mockEvent = {
      preventDefault: jest.fn()
    }
    
    reasonField.value = ""
    proofTypeInput.value = "income"
    
    controller.validateForm(mockEvent)
    
    expect(mockEvent.preventDefault).toHaveBeenCalled()
    expect(reasonField.classList.contains("border-red-500")).toBe(true)
    
    mockEvent.preventDefault.mockClear()
    
    reasonField.value = "Valid reason"
    
    controller.validateForm(mockEvent)
    
    expect(mockEvent.preventDefault).not.toHaveBeenCalled()
    expect(reasonField.classList.contains("border-red-500")).toBe(false)
  })
})
