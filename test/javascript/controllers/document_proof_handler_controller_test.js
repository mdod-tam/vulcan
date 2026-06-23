import DocumentProofHandlerController from "controllers/users/document_proof_handler_controller"

describe("DocumentProofHandlerController", () => {
  let controller
  let fileInput
  let form
  let rejectionReasonSelect

  beforeEach(() => {
    document.body.innerHTML = `
      <form>
        <input type="radio" name="income_proof_action" value="upload_only">
        <input type="radio" name="income_proof_action" value="accept">
        <input type="radio" name="income_proof_action" value="reject">
        <div data-document-proof-handler-target="uploadSection"></div>
        <div data-document-proof-handler-target="rejectionSection"></div>
        <input type="file" name="income_proof">
        <select name="income_proof_rejection_reason">
          <option value="">Select a reason</option>
          <option value="none_provided">None provided</option>
        </select>
      </form>
    `

    controller = new DocumentProofHandlerController()
    form = document.querySelector("form")
    fileInput = document.querySelector('input[type="file"]')
    rejectionReasonSelect = document.querySelector("select")

    Object.defineProperty(controller, "hasAcceptRadioTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "acceptRadioTarget", {
      value: document.querySelector('input[value="accept"]'),
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasUploadOnlyRadioTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "uploadOnlyRadioTarget", {
      value: document.querySelector('input[value="upload_only"]'),
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "rejectRadioTarget", {
      value: document.querySelector('input[value="reject"]'),
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasRejectRadioTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasFileInputTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "fileInputTarget", {
      value: fileInput,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasRejectionReasonSelectTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "rejectionReasonSelectTarget", {
      value: rejectionReasonSelect,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasReasonPreviewTarget", {
      value: false,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasLanguageNoticeTarget", {
      value: false,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasCustomReasonSectionTarget", {
      value: false,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasCustomReasonFieldTarget", {
      value: false,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasUploadSectionTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "uploadSectionTarget", {
      value: document.querySelector("[data-document-proof-handler-target='uploadSection']"),
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasRejectionSectionTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "rejectionSectionTarget", {
      value: document.querySelector("[data-document-proof-handler-target='rejectionSection']"),
      writable: false,
      configurable: true
    })
  })

  afterEach(() => {
    document.body.innerHTML = ""
  })

  test("none provided dispatches a bubbling change event after selecting reject", () => {
    const changeHandler = jest.fn()
    form.addEventListener("change", changeHandler)

    controller.handleNoneProvided()

    expect(controller.rejectRadioTarget.checked).toBe(true)
    expect(rejectionReasonSelect.value).toBe("none_provided")
    expect(fileInput.disabled).toBe(true)
    expect(changeHandler).toHaveBeenCalledTimes(1)
    expect(changeHandler.mock.calls[0][0].target).toBe(controller.rejectRadioTarget)
  })
})
