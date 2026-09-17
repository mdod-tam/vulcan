import { Application } from "@hotwired/stimulus"
import DocumentProofHandlerController from "controllers/users/document_proof_handler_controller"
import PaperApplicationController from "controllers/forms/paper_application_controller"

describe("paper uploads across a server review", () => {
  let application, form, proof, input, controller
  beforeEach(async () => {
    document.body.innerHTML = `
      <form data-controller="paper-application" data-action="submit->paper-application#beforeSubmit">
        <div data-controller="document-proof-handler">
          <input type="radio" name="income_proof_action" value="upload_only" checked data-document-proof-handler-target="uploadOnlyRadio">
          <input type="radio" name="income_proof_action" value="accept" data-document-proof-handler-target="acceptRadio">
          <input type="radio" name="income_proof_action" value="reject" data-document-proof-handler-target="rejectRadio">
          <div data-document-proof-handler-target="uploadSection">
            <input type="hidden" name="income_proof_signed_id" value="restored">
            <input type="file" name="income_proof_signed_id" data-document-proof-handler-target="fileInput">
            <p data-document-proof-handler-target="savedUpload">Uploaded: original.pdf</p>
            <button type="button" data-document-proof-handler-target="removeUpload">Remove</button>
            <button type="button" hidden data-document-proof-handler-target="cancelUpload">Cancel</button>
          </div>
          <div data-document-proof-handler-target="rejectionSection"></div>
        </div>
        <p data-paper-application-target="status"></p>
        <button type="submit" data-paper-application-target="submitButton">Submit</button>
      </form>`
    application = Application.start()
    application.register("document-proof-handler", DocumentProofHandlerController)
    application.register("paper-application", PaperApplicationController)
    await new Promise(resolve => setTimeout(resolve, 0))
    form = document.querySelector("form")
    proof = form.querySelector('[data-controller="document-proof-handler"]')
    input = proof.querySelector('input[type="file"]')
    controller = application.getControllerForElementAndIdentifier(proof, "document-proof-handler")
  })

  afterEach(() => { application.stop(); document.body.innerHTML = "" })

  test("normal submission is not intercepted for identity review", () => {
    const submit = new Event("submit", { bubbles: true, cancelable: true })
    form.dispatchEvent(submit)
    expect(submit.defaultPrevented).toBe(false)
    expect(new FormData(form).get("income_proof_signed_id")).toBe("restored")
  })

  test("replacement retains only the completed upload and removal clears its reference", () => {
    controller.uploadStarted()
    expect(proof.querySelector('input[type="radio"]').disabled).toBe(true)
    const replacement = document.createElement("input")
    Object.assign(replacement, { type: "hidden", name: input.name, value: "replacement" })
    input.before(replacement)
    controller.uploadFinished()
    expect(new FormData(form).getAll(input.name).filter(value => typeof value === "string")).toEqual(["replacement"])
    controller.removeUpload()
    expect(proof.querySelector('input[type="hidden"]')).toBeNull()
    expect(controller.savedUploadTarget.textContent).toBe("")
  })

  test("failed replacement keeps the restored upload and releases the controls", () => {
    controller.uploadStarted()
    controller.uploadFailed(new Event("direct-upload:error", { cancelable: true }))
    controller.uploadFinished()
    expect(new FormData(form).get(input.name)).toBe("restored")
    expect(controller.savedUploadTarget.textContent).toContain("Upload failed")
    expect(controller.removeUploadTarget.disabled).toBe(false)
  })

  test("choosing rejection clears a previously uploaded reference", () => {
    controller.rejectRadioTarget.checked = true
    controller.updateVisibility()
    expect(new FormData(form).has(input.name)).toBe(false)
  })

  test("cancellation follows the uploader error path and preserves the saved reference", () => {
    controller.uploadStarted()
    const xhr = new EventTarget()
    xhr.abort = jest.fn(() => xhr.dispatchEvent(new Event('abort')))
    xhr.addEventListener('error', () => {
      controller.uploadFailed(new Event('direct-upload:error', { cancelable: true }))
      controller.uploadFinished()
    })
    controller.rememberUploadRequest({ detail: { xhr } })
    expect(controller.cancelUploadTarget.disabled).toBe(false)
    controller.cancelUpload()
    expect(xhr.abort).toHaveBeenCalledTimes(1)
    expect(new FormData(form).get(input.name)).toBe('restored')
    expect(controller.savedUploadTarget.textContent).toContain('canceled')
    expect(controller.uploading).toBe(false)
  })

  test("a form upload failure unlocks proofs still waiting in the Rails upload queue", () => {
    controller.uploadStarted()
    form.dispatchEvent(new Event('direct-uploads:end'))
    expect(controller.uploading).toBe(false)
    expect(controller.uploadOnlyRadioTarget.disabled).toBe(false)
    expect(controller.removeUploadTarget.disabled).toBe(false)
    expect(new FormData(form).get(input.name)).toBe('restored')
  })

  test("uploads temporarily gate submit and release it on completion", () => {
    form.dispatchEvent(new Event("direct-uploads:start"))
    const submit = form.querySelector('button[type="submit"]')
    expect(submit.disabled).toBe(true)
    form.dispatchEvent(new Event("direct-uploads:end"))
    expect(submit.disabled).toBe(false)
  })
})
