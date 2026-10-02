import { Application } from "@hotwired/stimulus"
import DocumentUploadController from "controllers/ui/document_upload_controller"

describe("DocumentUploadController selection checks", () => {
  let application, widget, input, upload

  const render = async ({ maxBytes = 10, inclusive = true } = {}) => {
    document.body.innerHTML = `
      <form>
        <div data-controller="document-upload"
             data-document-upload-allowed-types-value='["application/pdf","image/heic","image/tiff"]'
             data-document-upload-max-bytes-value="${maxBytes}"
             data-document-upload-max-inclusive-value="${inclusive}"
             data-document-upload-invalid-type-message-value="Upload a PDF file."
             data-document-upload-too-large-message-value="Upload a smaller file."
             data-document-upload-selected-text-value="Selected: %{filename}">
          <input type="file" name="w9_form" data-document-upload-target="input" data-action="change->document-upload#select">
          <p data-document-upload-target="status"></p>
          <progress hidden data-document-upload-target="progress"></progress>
          <button type="button" hidden data-document-upload-target="remove">Remove</button>
          <button type="button" hidden data-document-upload-target="cancel">Cancel</button>
        </div>
      </form>`
    application = Application.start()
    application.register("document-upload", DocumentUploadController)
    await new Promise(resolve => setTimeout(resolve, 0))
    widget = document.querySelector('[data-controller="document-upload"]')
    input = widget.querySelector("input")
    upload = application.getControllerForElementAndIdentifier(widget, "document-upload")
  }

  const choose = (name, type, size) => {
    const file = new File(["x".repeat(size)], name, { type })
    Object.defineProperty(input, "files", { value: [file], configurable: true })
    input.dispatchEvent(new Event("change"))
  }

  afterEach(() => { application.stop(); document.body.innerHTML = "" })

  test("an allowed file is announced and kept", async () => {
    await render()
    choose("proof.pdf", "application/pdf", 10)
    expect(upload.statusTarget.textContent).toBe("Selected: proof.pdf")
  })

  test("a disallowed type is refused with the server wording", async () => {
    await render()
    const clear = jest.spyOn(input, "value", "set")
    choose("notes.txt", "text/plain", 1)
    expect(upload.statusTarget.textContent).toBe("Upload a PDF file.")
    expect(clear).toHaveBeenCalledWith("")
  })

  test("an extension stands in when the browser reports no type", async () => {
    await render()
    choose("scan.HEIC", "", 1)
    expect(upload.statusTarget.textContent).toBe("Selected: scan.HEIC")
    choose("scan.tif", "", 1)
    expect(upload.statusTarget.textContent).toBe("Selected: scan.tif")
  })

  test("an inclusive limit accepts a file of exactly the maximum size", async () => {
    await render({ maxBytes: 10, inclusive: true })
    choose("proof.pdf", "application/pdf", 10)
    expect(upload.statusTarget.textContent).toBe("Selected: proof.pdf")
    choose("proof.pdf", "application/pdf", 11)
    expect(upload.statusTarget.textContent).toBe("Upload a smaller file.")
  })

  test("a strict limit refuses a file of exactly the maximum size", async () => {
    await render({ maxBytes: 10, inclusive: false })
    choose("w9.pdf", "application/pdf", 10)
    expect(upload.statusTarget.textContent).toBe("Upload a smaller file.")
  })

  test("remove is offered only while there is a file to clear", async () => {
    await render()
    expect(upload.removeTarget.hidden).toBe(true)
    choose("proof.pdf", "application/pdf", 10)
    expect(upload.removeTarget.hidden).toBe(false)
    Object.defineProperty(input, "files", { value: [], configurable: true })
    upload.remove()
    expect(upload.removeTarget.hidden).toBe(true)
  })

  test("remove is ignored while an upload is in progress", async () => {
    await render()
    upload.uploadStarted()
    upload.statusTarget.textContent = "Uploading"
    upload.remove()
    expect(upload.statusTarget.textContent).toBe("Uploading")
    expect(upload.removeTarget.disabled).toBe(true)
  })
})
