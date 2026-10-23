import { Application } from "@hotwired/stimulus"
import DocumentProofHandlerController from "controllers/users/document_proof_handler_controller"
import DocumentUploadController from "controllers/ui/document_upload_controller"
import PaperApplicationController from "controllers/forms/paper_application_controller"

const flush = () => new Promise(resolve => setTimeout(resolve, 0))
const pending = { id: 7, status: "pending", filename: "replacement.pdf", status_url: "/document_scans/7" }
const clean = { ...pending, status: "clean", signed_id: "cleared-replacement" }

describe("paper document decisions and shared virus-check control", () => {
  let application, form, widget, input, upload

  beforeEach(async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, status: 200, json: async () => null })
    document.body.innerHTML = `
      <form data-controller="paper-application">
        <div data-controller="document-proof-handler">
          <input type="radio" name="income_proof_action" value="upload_only" checked
                 data-action="change->document-proof-handler#toggleProofAction" data-document-proof-handler-target="uploadOnlyRadio">
          <input type="radio" name="income_proof_action" value="accept"
                 data-action="change->document-proof-handler#toggleProofAction" data-document-proof-handler-target="acceptRadio">
          <input type="radio" name="income_proof_action" value="reject"
                 data-action="change->document-proof-handler#toggleProofAction" data-document-proof-handler-target="rejectRadio">
          <div data-document-proof-handler-target="uploadSection">
            <div data-controller="document-upload"
                 data-action="document-upload:clear->document-upload#remove"
                 data-document-upload-scans-url-value="/document_scans"
                 data-document-upload-purpose-value="proof"
                 data-document-upload-slot-value="income_proof"
                 data-document-upload-context-value="paper-form-uuid"
                 data-document-upload-retained-name-value="income_proof_signed_id"
                 data-document-upload-retained-filename-value="original.pdf"
                 data-document-upload-invalid-type-message-value="Upload a PDF file."
                 data-document-upload-allowed-types-value='["application/pdf"]'
                 data-document-upload-max-bytes-value="5242880"
                 data-document-upload-max-inclusive-value="true"
                 data-document-upload-uploaded-text-value="Ready: %{filename}"
                 data-document-upload-scanning-text-value="Checking %{filename} for viruses"
                 data-document-upload-canceled-text-value="Upload canceled.">
              <input type="file" name="income_proof" data-document-upload-target="input" data-document-proof-handler-target="fileInput">
              <input type="hidden" name="income_proof_signed_id" value="restored" data-document-upload-target="retained">
              <p data-document-upload-target="status">Ready: original.pdf</p>
              <progress hidden data-document-upload-target="progress"></progress>
              <button type="button" data-document-upload-target="remove">Remove</button>
              <button type="button" hidden data-document-upload-target="cancel">Cancel</button>
              <button type="button" hidden data-document-upload-target="retry">Check again</button>
            </div>
          </div>
          <div data-document-proof-handler-target="rejectionSection"></div>
        </div>
        <input name="residency_proof" type="hidden" value="other-cleared-file">
        <p data-paper-application-target="status"></p>
        <button type="submit" data-paper-application-target="submitButton">Submit</button>
      </form>`
    application = Application.start()
    application.register("document-proof-handler", DocumentProofHandlerController)
    application.register("document-upload", DocumentUploadController)
    application.register("paper-application", PaperApplicationController)
    await flush()
    form = document.querySelector("form")
    widget = form.querySelector('[data-controller="document-upload"]')
    input = widget.querySelector('input[type="file"]')
    upload = application.getControllerForElementAndIdentifier(widget, "document-upload")
  })

  afterEach(async () => {
    application.stop()
    await flush()
    document.body.innerHTML = ""
    delete global.fetch
  })

  test("an unchanged retry keeps the server-retained upload and staff decision", () => {
    expect(new FormData(form).get("income_proof_signed_id")).toBe("restored")
    expect(new FormData(form).get("income_proof_action")).toBe("upload_only")
    expect(form.querySelector('button[type="submit"]').disabled).toBe(false)
  })

  test("pending scan blocks submit while preserving the staff decision and sibling file", () => {
    upload.applyStatus(pending)
    const data = new FormData(form)
    expect(data.get("income_proof_action")).toBe("upload_only")
    expect(data.get("residency_proof")).toBe("other-cleared-file")
    expect(data.has("income_proof")).toBe(false)
    expect(form.querySelector('button[type="submit"]').disabled).toBe(true)
  })

  test("a clean replacement provides one receipt and releases submit", () => {
    upload.applyStatus(pending)
    upload.applyStatus(clean)
    expect(new FormData(form).getAll("income_proof")).toEqual(["cleared-replacement"])
    expect(new FormData(form).has("income_proof_signed_id")).toBe(false)
    expect(new FormData(form).get("income_proof_action")).toBe("upload_only")
    expect(form.querySelector('button[type="submit"]').disabled).toBe(false)
  })

  test("staff can change upload-only to approval while scanning without submitting early", async () => {
    upload.applyStatus(pending)
    form.querySelector('input[value="accept"]').click()
    await flush()
    expect(new FormData(form).get("income_proof_action")).toBe("accept")
    expect(input.disabled).toBe(false)
    expect(form.querySelector('button[type="submit"]').disabled).toBe(true)
    upload.applyStatus(clean)
    expect(new FormData(form).get("income_proof_action")).toBe("accept")
    expect(form.querySelector('button[type="submit"]').disabled).toBe(false)
  })

  test("rejection dismisses the pending file and leaves other documents intact", async () => {
    upload.applyStatus(pending)
    form.querySelector('input[value="reject"]').click()
    await flush()
    expect(fetch).toHaveBeenCalledWith("/document_scans/7", expect.objectContaining({ method: "DELETE" }))
    const data = new FormData(form)
    expect(data.has("income_proof")).toBe(false)
    expect(data.has("income_proof_signed_id")).toBe(false)
    expect(data.get("income_proof_action")).toBe("reject")
    expect(data.get("residency_proof")).toBe("other-cleared-file")
    expect(input.disabled).toBe(true)
    expect(form.querySelector('button[type="submit"]').disabled).toBe(false)
  })

  test("an invalid new selection keeps the cleared file and the decision", async () => {
    upload.applyStatus(clean)
    Object.defineProperty(input, "files", { value: [new File(["x"], "notes.txt", { type: "text/plain" })], configurable: true })
    await upload.select()
    expect(upload.statusTarget.textContent).toBe("Upload a PDF file. Ready: replacement.pdf")
    expect(new FormData(form).get("income_proof")).toBe("cleared-replacement")
    expect(new FormData(form).get("income_proof_action")).toBe("upload_only")
  })
})
