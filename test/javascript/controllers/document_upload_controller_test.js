import { Application } from "@hotwired/stimulus"
import DocumentUploadController from "controllers/ui/document_upload_controller"

const response = data => ({ ok: true, status: 200, json: async () => data })
const pending = { id: 7, status: "pending", filename: "proof.pdf", status_url: "/document_scans/7", signed_id: null }
const clean = { ...pending, status: "clean", signed_id: "clean-receipt" }
const refusal = (status, message = "The replacement was refused.") => ({ ok: false, status, json: async () => ({ message }) })
const flush = () => new Promise(resolve => setTimeout(resolve, 0))

describe("document upload quarantine and scan control", () => {
  let application, upload, input, widget

  const render = async ({ initial = null, maxBytes = 10, inclusive = true, count = 1, retained = null, restoreResponse = null } = {}) => {
    global.fetch = jest.fn().mockResolvedValue(restoreResponse || response(initial))
    document.body.innerHTML = `<meta name="csrf-token" content="csrf-value"><form>${Array.from({ length: count }, (_n, i) => `
      <div data-controller="document-upload"
           data-document-upload-scans-url-value="/document_scans"
           data-document-upload-purpose-value="proof"
           data-document-upload-slot-value="income_proof"
           data-document-upload-context-value="application:1:2026"
           data-document-upload-retained-name-value="proof_${i}_signed_id"
           data-document-upload-retained-filename-value="${retained?.filename || ""}"
           data-document-upload-allowed-types-value='["application/pdf","image/heic","image/tiff"]'
           data-document-upload-max-bytes-value="${maxBytes}"
           data-document-upload-max-inclusive-value="${inclusive}"
           data-document-upload-invalid-type-message-value="Upload a PDF file."
           data-document-upload-too-large-message-value="Upload a smaller file."
           data-document-upload-uploading-text-value="Uploading %{filename}"
           data-document-upload-scanning-text-value="Checking %{filename} for viruses… You can keep filling out the form."
           data-document-upload-uploaded-text-value="Ready: %{filename}"
           data-document-upload-failed-text-value="Upload failed. Choose the file again."
           data-document-upload-unavailable-text-value="Your file is saved. Check again."
           data-document-upload-blocked-text-value="Choose a different file."
           data-document-upload-canceled-text-value="Upload canceled."
           data-document-upload-link-unavailable-text-value="This upload link expired. Ask for a new link."
           data-document-upload-session-expired-text-value="Refresh this page to sign in again."
           data-document-upload-wait-text-value="Wait for the virus check.">
        <input type="file" required name="proof_${i}" data-document-upload-target="input" data-action="change->document-upload#select">
        ${retained ? `<input type="hidden" name="proof_${i}_signed_id" value="${retained.signedId}" data-document-upload-target="retained">` : ""}
        <p role="status" data-document-upload-target="status"></p>
        <progress hidden data-document-upload-target="progress"></progress>
        <button type="button" hidden data-document-upload-target="remove">Remove</button>
        <button type="button" hidden data-document-upload-target="cancel">Cancel</button>
        <button type="button" hidden data-document-upload-target="retry">Check again</button>
      </div>`).join("")}<button type="submit">Submit</button></form>`
    application = Application.start()
    application.register("document-upload", DocumentUploadController)
    await flush()
    widget = document.querySelector('[data-controller="document-upload"]')
    input = widget.querySelector('input[type="file"]')
    upload = application.getControllerForElementAndIdentifier(widget, "document-upload")
  }

  const choose = (target = input, { name = "proof.pdf", type = "application/pdf", size = 5 } = {}) => {
    Object.defineProperty(target, "files", { value: [new File(["x".repeat(size)], name, { type })], configurable: true })
    target.dispatchEvent(new Event("change"))
    return flush()
  }

  afterEach(async () => {
    application?.stop()
    await flush()
    document.body.innerHTML = ""
    delete global.fetch
  })

  test("selection uploads private bytes immediately and blocks final submission until clean", async () => {
    await render()
    fetch.mockResolvedValueOnce(response(pending))
    await choose()
    const [url, options] = fetch.mock.calls.find(([_url, options]) => options.method === "POST")
    expect(url).toBe("/document_scans")
    expect(options.body.get("file").name).toBe("proof.pdf")
    expect(options.body.get("purpose")).toBe("proof")
    expect(options.body.get("context")).toBe("application:1:2026")
    expect(options.headers["X-CSRF-Token"]).toBe("csrf-value")
    expect(input.name).toBe("")
    expect(upload.statusTarget.textContent).toBe("Checking proof.pdf for viruses… You can keep filling out the form.")
    expect(input.validationMessage).toBe("Wait for the virus check.")
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(false)
  })

  test("an ongoing transfer gives a submission instruction without replacing its progress text", async () => {
    await render()
    let finish
    fetch.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    await choose()
    expect(upload.statusTarget.textContent).toBe("Uploading proof.pdf")
    expect(input.validationMessage).toBe("Wait for the virus check.")
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(false)
    finish(response(clean))
    await flush()
    expect(input.validationMessage).toBe("")
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(true)
  })

  test("clean status enables submission and supplies only the cleared receipt", async () => {
    await render({ initial: pending })
    fetch.mockResolvedValueOnce(response(clean))
    await upload.check()
    await flush()
    expect(upload.statusTarget.textContent).toBe("Ready: proof.pdf")
    expect(input.required).toBe(false)
    expect(input.validationMessage).toBe("")
    expect(upload.retainedTarget.name).toBe("proof_0")
    expect(upload.retainedTarget.value).toBe("clean-receipt")
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(true)
  })

  test("infected, unknown, and failed results never provide a receipt", async () => {
    await render()
    for (const status of ["infected", "suspicious", "failed", "unexpected"]) {
      upload.applyStatus({ ...pending, status, message: "File blocked" })
      expect(upload.state).toBe("blocked")
      expect(widget.querySelector('input[type="hidden"]')).toBeNull()
      expect(input.validationMessage).toBe("File blocked")
    }
  })

  test("a failed status request keeps the saved upload blocked and can be retried", async () => {
    await render({ initial: pending })
    fetch.mockRejectedValueOnce(new Error("network"))
    await upload.check()
    expect(upload.retryTarget.hidden).toBe(false)
    expect(upload.statusTarget.textContent).toBe("Your file is saved. Check again.")
    expect(input.validationMessage).not.toBe("")
    fetch.mockResolvedValueOnce(response(clean))
    await upload.check()
    expect(upload.retryTarget.hidden).toBe(true)
    expect(upload.state).toBe("clean")
  })

  test("an expired secure link explains how to get a new link instead of suggesting a network retry", async () => {
    await render({ initial: pending })
    upload.secureFormTypeValue = "proof"
    fetch.mockResolvedValueOnce({ ok: false, status: 404, json: async () => { throw new SyntaxError("Empty response") } })
    await upload.check()
    expect(upload.statusTarget.textContent).toBe("This upload link expired. Ask for a new link.")
    expect(input.validationMessage).toBe("This upload link expired. Ask for a new link.")
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
  })

  test("an expired session explains reauthentication while retaining the private upload", async () => {
    await render({ initial: pending })
    fetch.mockResolvedValueOnce({ ok: false, status: 401, json: async () => { throw new SyntaxError("Empty response") } })
    await upload.check()
    expect(upload.statusTarget.textContent).toBe("Refresh this page to sign in again.")
    expect(upload.scanUrl).toBe("/document_scans/7")
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
  })

  test("reload recovers a pending upload from the same owner and form context", async () => {
    await render({ initial: pending })
    expect(upload.state).toBe("pending")
    const url = new URL(fetch.mock.calls[0][0])
    expect(url.searchParams.get("context")).toBe("application:1:2026")
    expect(input.name).toBe("")
  })

  test("one blocked file does not discard another field's clean receipt", async () => {
    await render({ count: 2 })
    const secondWidget = document.querySelectorAll('[data-controller="document-upload"]')[1]
    const second = application.getControllerForElementAndIdentifier(secondWidget, "document-upload")
    upload.applyStatus(clean)
    second.applyStatus({ ...pending, id: 8, status: "infected", message: "File blocked" })
    await flush()
    expect(upload.retainedTarget.value).toBe("clean-receipt")
    expect(secondWidget.querySelector('input[type="hidden"]')).toBeNull()
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(false)
  })

  test("remove dismisses the exact saved scan and clears the receipt", async () => {
    await render({ initial: clean })
    fetch.mockResolvedValueOnce({ ok: true, status: 204 })
    upload.remove()
    await flush()
    expect(fetch).toHaveBeenCalledWith("/document_scans/7", expect.objectContaining({ method: "DELETE" }))
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
    expect(input.name).toBe("proof_0")
    expect(upload.state).toBe("idle")
  })

  test("cancel during upload dismisses its eventual saved scan instead of restoring it", async () => {
    await render()
    let finish
    fetch.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    await choose()
    upload.cancel()
    fetch.mockResolvedValueOnce({ ok: true, status: 204 })
    finish(response(pending))
    await flush()
    await flush()
    expect(fetch).toHaveBeenCalledWith("/document_scans/7", expect.objectContaining({ method: "DELETE" }))
    expect(upload.state).toBe("idle")
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
  })

  test("a clean polling response arriving after remove cannot restore its receipt", async () => {
    await render({ initial: pending })
    let finish
    fetch.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    const checking = upload.check()
    fetch.mockResolvedValueOnce({ ok: true, status: 204 })
    upload.remove()
    finish(response(clean))
    await checking
    await flush()
    expect(fetch).toHaveBeenCalledWith("/document_scans/7", expect.objectContaining({ method: "DELETE" }))
    expect(upload.state).toBe("idle")
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
    expect(input.name).toBe("proof_0")
    expect(input.validity.customError).toBe(false)
    expect(input.required).toBe(true)
  })

  test("leaving during an upload keeps its eventual saved scan recoverable", async () => {
    await render()
    let finish
    fetch.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    await choose()
    upload.disconnect()
    finish(response(pending))
    await flush()
    expect(fetch.mock.calls.filter(([_url, options]) => options.method === "DELETE")).toHaveLength(0)
  })

  test("disallowed selections keep an earlier cleared receipt", async () => {
    await render({ initial: clean })
    await choose(input, { name: "notes.txt", type: "text/plain" })
    expect(upload.statusTarget.textContent).toBe("Upload a PDF file. Ready: proof.pdf")
    expect(upload.retainedTarget.value).toBe("clean-receipt")
  })

  test.each([422, 429])("a definitive %s replacement refusal preserves the original clean selection across retries", async status => {
    await render({ initial: clean })
    for (const name of ["first-replacement.pdf", "second-replacement.pdf"]) {
      fetch.mockResolvedValueOnce(refusal(status))
      await choose(input, { name })
      expect(upload.state).toBe("clean")
      expect(upload.statusTarget.textContent).toBe("The replacement was refused. Ready: proof.pdf")
      expect(upload.retainedTarget.value).toBe("clean-receipt")
      expect(upload.scanUrl).toBe("/document_scans/7")
      expect(input.validationMessage).toBe("")
      expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(true)
    }
    expect(fetch.mock.calls.filter(([_url, options]) => options.method === "DELETE")).toHaveLength(0)
  })

  test("a quick replacement refusal preserves the server-retained receipt before recovery finishes", async () => {
    let finishRestore
    const restoring = new Promise(resolve => { finishRestore = resolve })
    await render({ retained: { signedId: "server-receipt", filename: "server.pdf" }, restoreResponse: restoring })
    expect(upload.state).toBe("idle")
    fetch.mockResolvedValueOnce(refusal(422))
    await choose(input, { name: "replacement.pdf" })
    expect(upload.state).toBe("clean")
    expect(upload.statusTarget.textContent).toBe("The replacement was refused. Ready: server.pdf")
    expect(upload.retainedTarget.value).toBe("server-receipt")
    finishRestore(response(clean))
    await flush()
    expect(upload.retainedTarget.value).toBe("server-receipt")
    expect(fetch.mock.calls.filter(([_url, options]) => options.method === "DELETE")).toHaveLength(0)
  })

  test("accepting the new pending scan dismisses the prior clean choice and never falls back after a blocked verdict", async () => {
    await render({ initial: clean })
    let finish
    fetch.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    await choose(input, { name: "replacement.pdf" })
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
    expect(fetch.mock.calls.filter(([_url, options]) => options.method === "DELETE")).toHaveLength(0)
    fetch.mockResolvedValue({ ok: true, status: 204 })
    const replacement = { ...pending, id: 8, filename: "replacement.pdf", status_url: "/document_scans/8" }
    finish(response(replacement))
    await flush()
    expect(fetch).toHaveBeenCalledWith("/document_scans/7", expect.objectContaining({ method: "DELETE" }))
    expect(upload.state).toBe("pending")
    upload.applyStatus({ ...replacement, status: "blocked", message: "File blocked" })
    expect(upload.state).toBe("blocked")
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(false)
  })

  test.each([401, 404, 500, "network"])("a %s staging failure cannot restore an earlier receipt without an authorized status result", async status => {
    await render({ initial: clean })
    upload.secureFormTypeValue = "proof"
    if (status === "network") fetch.mockRejectedValueOnce(new Error("network"))
    else fetch.mockResolvedValueOnce(refusal(status))
    await choose(input, { name: "replacement.pdf" })
    expect(upload.state).toBe("unavailable")
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(false)
    expect(fetch.mock.calls.filter(([_url, options]) => options.method === "DELETE")).toHaveLength(0)
  })

  test("canceling a replacement dismisses both the earlier selection and the late new scan", async () => {
    await render({ initial: clean })
    let finish
    fetch.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    await choose(input, { name: "replacement.pdf" })
    fetch.mockResolvedValue({ ok: true, status: 204 })
    upload.cancel()
    finish(response({ ...pending, id: 8, status_url: "/document_scans/8" }))
    await flush()
    expect(fetch).toHaveBeenCalledWith("/document_scans/7", expect.objectContaining({ method: "DELETE" }))
    expect(fetch).toHaveBeenCalledWith("/document_scans/8", expect.objectContaining({ method: "DELETE" }))
    expect(upload.state).toBe("idle")
    expect(widget.querySelector('input[type="hidden"]')).toBeNull()
  })

  test("a superseded response cannot discard the clean selection needed by the current replacement", async () => {
    await render({ initial: clean })
    let finishFirst, finishSecond
    fetch.mockReturnValueOnce(new Promise(resolve => { finishFirst = resolve }))
    await choose(input, { name: "first.pdf" })
    fetch.mockReturnValueOnce(new Promise(resolve => { finishSecond = resolve }))
    await choose(input, { name: "second.pdf" })
    fetch.mockResolvedValue({ ok: true, status: 204 })
    finishFirst(response({ ...pending, id: 8, status_url: "/document_scans/8" }))
    await flush()
    finishSecond(refusal(422))
    await flush()
    expect(fetch).toHaveBeenCalledWith("/document_scans/8", expect.objectContaining({ method: "DELETE" }))
    expect(fetch).not.toHaveBeenCalledWith("/document_scans/7", expect.objectContaining({ method: "DELETE" }))
    expect(upload.state).toBe("clean")
    expect(upload.retainedTarget.value).toBe("clean-receipt")
  })

  test("a Turbo reconnect keeps the original field name and required rule", async () => {
    await render({ initial: clean })
    application.stop()
    await flush()
    application = Application.start()
    application.register("document-upload", DocumentUploadController)
    await flush()
    upload = application.getControllerForElementAndIdentifier(widget, "document-upload")
    expect(upload.retainedTarget.name).toBe("proof_0")
    fetch.mockResolvedValueOnce({ ok: true, status: 204 })
    upload.remove()
    expect(input.name).toBe("proof_0")
    expect(input.required).toBe(true)
  })

  test("an unselected document source cannot block saving an external link", async () => {
    await render({ initial: pending })
    const source = document.createElement("select")
    source.id = "source"
    source.innerHTML = '<option value="url">Link</option><option value="pdf">PDF</option>'
    document.querySelector("form").prepend(source)
    upload.activeSelectorValue = "#source"
    upload.activeValueValue = "pdf"
    upload.syncActive()
    expect(input.disabled).toBe(true)
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(true)
    source.value = "pdf"
    source.dispatchEvent(new Event("change", { bubbles: true }))
    expect(input.disabled).toBe(false)
    expect(document.querySelector("form").dispatchEvent(new Event("submit", { cancelable: true }))).toBe(false)
  })

  test("type hints and inclusive versus strict size limits match server policy", async () => {
    await render()
    expect(upload.refusalFor(new File(["x"], "scan.HEIC", { type: "" }))).toBeNull()
    expect(upload.refusalFor(new File(["x".repeat(10)], "proof.pdf", { type: "application/pdf" }))).toBeNull()
    expect(upload.refusalFor(new File(["x".repeat(11)], "proof.pdf", { type: "application/pdf" }))).toBe("Upload a smaller file.")
    upload.maxInclusiveValue = false
    expect(upload.refusalFor(new File(["x".repeat(10)], "proof.pdf", { type: "application/pdf" }))).toBe("Upload a smaller file.")
  })
})
