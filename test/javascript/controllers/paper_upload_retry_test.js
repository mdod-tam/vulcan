import { Application } from "@hotwired/stimulus"
import DocumentProofHandlerController from "controllers/users/document_proof_handler_controller"
import DocumentUploadController from "controllers/ui/document_upload_controller"
import PaperApplicationController from "controllers/forms/paper_application_controller"

describe("paper uploads across a server review", () => {
  let application, form, proof, widget, input, upload, handler

  beforeEach(async () => {
    document.body.innerHTML = `
      <form data-controller="paper-application" data-action="submit->paper-application#beforeSubmit">
        <div data-controller="document-proof-handler">
          <input type="radio" name="income_proof_action" value="upload_only" checked data-document-proof-handler-target="uploadOnlyRadio">
          <input type="radio" name="income_proof_action" value="accept" data-document-proof-handler-target="acceptRadio">
          <input type="radio" name="income_proof_action" value="reject" data-document-proof-handler-target="rejectRadio">
          <div data-document-proof-handler-target="uploadSection">
            <div data-controller="document-upload"
                 data-action="document-upload:clear->document-upload#remove"
                 data-document-upload-retained-name-value="income_proof_signed_id"
                 data-document-upload-allowed-types-value='["application/pdf"]'
                 data-document-upload-max-bytes-value="5242880"
                 data-document-upload-max-inclusive-value="true"
                 data-document-upload-uploaded-text-value="Uploaded: %{filename}"
                 data-document-upload-uploading-text-value="Uploading %{filename}"
                 data-document-upload-canceled-text-value="Upload canceled. Any earlier upload is kept."
                 data-document-upload-failed-text-value="Upload failed. Any earlier upload is kept.">
              <input type="file" name="income_proof" data-document-upload-target="input" data-document-proof-handler-target="fileInput">
              <input type="hidden" name="income_proof_signed_id" value="restored" data-document-upload-target="retained">
              <p data-document-upload-target="status">Uploaded: original.pdf</p>
              <progress hidden data-document-upload-target="progress"></progress>
              <button type="button" data-document-upload-target="remove">Remove</button>
              <button type="button" hidden data-document-upload-target="cancel">Cancel</button>
            </div>
          </div>
          <div data-document-proof-handler-target="rejectionSection"></div>
        </div>
        <p data-paper-application-target="status"></p>
        <button type="submit" data-paper-application-target="submitButton">Submit</button>
      </form>`
    application = Application.start()
    application.register("document-proof-handler", DocumentProofHandlerController)
    application.register("document-upload", DocumentUploadController)
    application.register("paper-application", PaperApplicationController)
    await new Promise(resolve => setTimeout(resolve, 0))
    form = document.querySelector("form")
    proof = form.querySelector('[data-controller="document-proof-handler"]')
    widget = form.querySelector('[data-controller="document-upload"]')
    input = widget.querySelector('input[type="file"]')
    handler = application.getControllerForElementAndIdentifier(proof, "document-proof-handler")
    upload = application.getControllerForElementAndIdentifier(widget, "document-upload")
  })

  afterEach(() => { application.stop(); document.body.innerHTML = "" })

  // Rails names the hidden signed-ID input after the file input while it uploads
  const completeUpload = (signedId) => {
    const uploaded = document.createElement("input")
    Object.assign(uploaded, { type: "hidden", name: input.name, value: signedId })
    input.before(uploaded)
  }
  const startUpload = () => input.dispatchEvent(new Event("direct-upload:initialize", { bubbles: true }))

  test("normal submission is not intercepted and carries the retained upload", () => {
    const submit = new Event("submit", { bubbles: true, cancelable: true })
    form.dispatchEvent(submit)
    expect(submit.defaultPrevented).toBe(false)
    expect(new FormData(form).get("income_proof_signed_id")).toBe("restored")
  })

  test("a completed replacement keeps the retained upload until the server decides", () => {
    upload.uploadStarted()
    completeUpload("replacement")
    upload.finished()
    // The server prefers the replacement and falls back to the retained upload if it refuses it
    expect(new FormData(form).get("income_proof")).toBe("replacement")
    expect(new FormData(form).get("income_proof_signed_id")).toBe("restored")
  })

  test("remove clears the retained upload and the reference Rails added for a completed upload", () => {
    upload.uploadStarted()
    completeUpload("completed")
    upload.finished()
    upload.remove()
    const data = new FormData(form)
    expect(data.has("income_proof_signed_id")).toBe(false)
    expect(data.getAll("income_proof").filter(value => typeof value === "string")).toEqual([])
    expect(upload.statusTarget.textContent).toBe("")
  })

  test("a successful new attempt makes the interrupted earlier upload the retained one", () => {
    upload.uploadStarted()
    completeUpload("first")
    upload.finished()
    // The form submission stopped elsewhere; Rails uploads a newly chosen replacement
    upload.uploadStarted()
    completeUpload("second")
    upload.finished()
    // The server prefers the replacement and can fall back to the earlier upload if it refuses it
    const data = new FormData(form)
    expect(data.getAll("income_proof").filter(value => typeof value === "string")).toEqual(["second"])
    expect(data.getAll("income_proof_signed_id")).toEqual(["first"])
  })

  test("an interrupted earlier upload is retained even when nothing was retained before", () => {
    upload.remove()
    upload.uploadStarted()
    completeUpload("first")
    upload.finished()
    upload.uploadStarted()
    completeUpload("second")
    upload.finished()
    expect(new FormData(form).getAll("income_proof_signed_id")).toEqual(["first"])
    upload.remove()
    expect(new FormData(form).has("income_proof_signed_id")).toBe(false)
  })

  test("a canceled new attempt keeps the reference completed in an interrupted earlier one", () => {
    upload.uploadStarted()
    completeUpload("first")
    upload.finished()
    upload.uploadStarted()
    upload.failed(new Event("direct-upload:error", { cancelable: true }))
    upload.finished()
    expect(new FormData(form).getAll("income_proof").filter(value => typeof value === "string")).toEqual(["first"])
    expect(new FormData(form).get("income_proof_signed_id")).toBe("restored")
  })

  test("a failed replacement keeps the retained upload and releases the controls", () => {
    upload.uploadStarted()
    upload.failed(new Event("direct-upload:error", { cancelable: true }))
    upload.finished()
    expect(new FormData(form).get("income_proof_signed_id")).toBe("restored")
    expect(upload.statusTarget.textContent).toContain("Upload failed")
    expect(upload.removeTarget.disabled).toBe(false)
  })

  test("choosing rejection clears the retained upload", () => {
    handler.rejectRadioTarget.checked = true
    handler.updateVisibility()
    expect(new FormData(form).has("income_proof_signed_id")).toBe(false)
    expect(input.disabled).toBe(true)
  })

  test("cancellation follows the uploader error path and keeps the retained upload", () => {
    upload.uploadStarted()
    const xhr = new EventTarget()
    xhr.abort = jest.fn(() => xhr.dispatchEvent(new Event("abort")))
    xhr.addEventListener("error", () => {
      upload.failed(new Event("direct-upload:error", { cancelable: true }))
      upload.finished()
    })
    upload.rememberRequest({ detail: { xhr } })
    expect(upload.cancelTarget.hidden).toBe(false)
    upload.cancel()
    expect(xhr.abort).toHaveBeenCalledTimes(1)
    expect(new FormData(form).get("income_proof_signed_id")).toBe("restored")
    expect(upload.statusTarget.textContent).toContain("canceled")
    expect(upload.uploading).toBe(false)
  })

  test("decisions are locked during an upload but still submitted with the form", () => {
    const clickAccept = () => {
      const click = new MouseEvent("click", { bubbles: true, cancelable: true })
      handler.acceptRadioTarget.dispatchEvent(click)
      return click.defaultPrevented
    }
    startUpload()
    expect(handler.uploadOnlyRadioTarget.getAttribute("aria-disabled")).toBe("true")
    // Rails submits the form before it fires direct-uploads:end, so the decision must stay enabled
    expect(new FormData(form).get("income_proof_action")).toBe("upload_only")
    expect(clickAccept()).toBe(true)

    form.dispatchEvent(new Event("direct-uploads:end"))
    expect(handler.uploadOnlyRadioTarget.hasAttribute("aria-disabled")).toBe(false)
    expect(clickAccept()).toBe(false)
  })

  test("a form upload failure releases a widget still waiting in the Rails upload queue", () => {
    upload.uploadStarted()
    form.dispatchEvent(new Event("direct-uploads:end"))
    expect(upload.uploading).toBe(false)
    expect(upload.removeTarget.disabled).toBe(false)
    expect(new FormData(form).get("income_proof_signed_id")).toBe("restored")
  })

  test("uploads temporarily gate submit and release it on completion", () => {
    form.dispatchEvent(new Event("direct-uploads:start"))
    const submit = form.querySelector('button[type="submit"]')
    expect(submit.disabled).toBe(true)
    form.dispatchEvent(new Event("direct-uploads:end"))
    expect(submit.disabled).toBe(false)
  })
})
