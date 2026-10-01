import { Application } from "@hotwired/stimulus"
import UploadController from "controllers/ui/upload_controller"
import { DirectUpload } from "@rails/activestorage"

// Mock DirectUpload
jest.mock("@rails/activestorage", () => ({
  DirectUpload: jest.fn()
}))

describe("UploadController", () => {
  let application
  let controller
  let element
  let progressBar
  let submitButton
  let cancelButton
  let fileInput

  beforeEach(() => {
    // Mock alert since jsdom doesn't implement it
    global.alert = jest.fn()
    
    // Set up DOM
    document.body.innerHTML = `
      <form data-controller="upload"
            data-upload-direct-upload-url-value="/rails/active_storage/direct_uploads"
            data-upload-allowed-types-value='["application/pdf","image/jpeg","image/png","image/heic","image/heif"]'
            data-upload-invalid-type-message-value="Invalid file type. Please upload a PDF or an image file (PDF, JPEG, PNG, or HEIC/HEIF)."
            data-upload-max-file-size-value="5242880">
        <input type="file" data-upload-target="input">
        <div data-upload-target="progress" class="hidden">
          <div role="progressbar" style="width: 0%" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100"></div>
          <span data-upload-target="percentage">0%</span>
        </div>
        <button type="submit" data-upload-target="submit">Submit</button>
        <button type="button" data-upload-target="cancel" class="hidden" data-action="click->upload#cancelUpload">Cancel Upload</button>
      </form>
    `

    element = document.querySelector("[data-controller='upload']")
    progressBar = element.querySelector("[data-upload-target='progress']")
    submitButton = element.querySelector("[data-upload-target='submit']")
    cancelButton = element.querySelector("[data-upload-target='cancel']")
    fileInput = element.querySelector("[data-upload-target='input']")

    // Create controller manually
    controller = new UploadController()
    
    // Mock the Stimulus properties
    Object.defineProperty(controller, 'element', {
      value: element,
      writable: false
    })
    
    Object.defineProperty(controller, 'inputTarget', {
      value: fileInput,
      writable: false
    })
    
    Object.defineProperty(controller, 'progressTarget', {
      value: progressBar,
      writable: false
    })
    
    Object.defineProperty(controller, 'submitTarget', {
      value: submitButton,
      writable: false
    })
    
    Object.defineProperty(controller, 'cancelTarget', {
      value: cancelButton,
      writable: false
    })
    
    Object.defineProperty(controller, 'percentageTarget', {
      value: element.querySelector("[data-upload-target='percentage']"),
      writable: false
    })
    
    Object.defineProperty(controller, 'directUploadUrlValue', {
      value: "/rails/active_storage/direct_uploads",
      writable: false
    })

    Object.defineProperty(controller, 'allowedTypesValue', {
      value: ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif"],
      writable: false
    })

    Object.defineProperty(controller, 'invalidTypeMessageValue', {
      value: "Invalid file type. Please upload a PDF or an image file (PDF, JPEG, PNG, or HEIC/HEIF).",
      writable: false
    })

    Object.defineProperty(controller, 'maxFileSizeValue', {
      value: 5 * 1024 * 1024,
      writable: false
    })

    // Call connect to initialize
    controller.connect()

    // Mock DirectUpload
    DirectUpload.mockImplementation(() => ({
      create: jest.fn((callback) => {
        // Simulate successful upload
        callback(null, { signed_id: "123" })
      })
    }))
  })

  afterEach(() => {
    document.body.innerHTML = ""
    jest.clearAllMocks()
    delete global.alert
  })

  test("shows progress bar when file selected", () => {
    const file = new File(["content"], "test.pdf", { type: "application/pdf" })
    const event = { target: { files: [file] } }

    controller.handleFileSelect(event)

    expect(progressBar.classList.contains("hidden")).toBe(false)
    expect(cancelButton.classList.contains("hidden")).toBe(false)
  })

  test("disables submit button during upload", () => {
    const file = new File(["content"], "test.pdf", { type: "application/pdf" })
    
    // Mock DirectUpload to not call callback immediately
    DirectUpload.mockImplementation(() => ({
      create: jest.fn() // Don't call callback, simulating ongoing upload
    }))
    
    controller.handleFileSelect({ target: { files: [file] } })
    
    expect(submitButton.disabled).toBe(true)
  })

  test("enables submit button after upload completes", () => {
    const file = new File(["content"], "test.pdf", { type: "application/pdf" })
    
    controller.handleFileSelect({ target: { files: [file] } })
    
    // The upload completes synchronously in our mock
    expect(submitButton.disabled).toBe(false)
  })

  test("handles upload cancellation", () => {
    const file = new File(["content"], "test.pdf", { type: "application/pdf" })
    
    // Mock XMLHttpRequest for cancellation
    const mockXHR = {
      abort: jest.fn(),
      upload: { addEventListener: jest.fn() }
    }
    
    controller.handleFileSelect({ target: { files: [file] } })
    controller.cancelToken = mockXHR // Simulate the XHR being set
    controller.uploadInProgress = true
    
    controller.cancelUpload()

    expect(mockXHR.abort).toHaveBeenCalled()
    expect(progressBar.classList.contains("hidden")).toBe(true)
    expect(cancelButton.classList.contains("hidden")).toBe(true)
  })

  test("validates file type", () => {
    const invalidFile = new File(["content"], "test.txt", { type: "text/plain" })
    
    const result = controller.validateFile(invalidFile)
    
    expect(result).toBe(false)
    expect(fileInput.value).toBe("")
  })

  test("validates file size", () => {
    // Create a file that's too large (over 5MB)
    const largeFile = new File(["x".repeat(6 * 1024 * 1024)], "large.pdf", { type: "application/pdf" })
    
    const result = controller.validateFile(largeFile)
    
    expect(result).toBe(false)
    expect(fileInput.value).toBe("")
  })

  test("updates progress during upload", () => {
    const file = new File(["content"], "test.pdf", { type: "application/pdf" })
    
    controller.handleFileSelect({ target: { files: [file] } })

    // Simulate progress update
    const progressEvent = {
      lengthComputable: true,
      loaded: 50,
      total: 100
    }
    
    controller.updateProgress(progressEvent)

    const progressElement = progressBar.querySelector("[role='progressbar']")
    const percentageElement = progressBar.querySelector("[data-upload-target='percentage']")
    
    expect(progressElement.style.width).toBe("50%")
    expect(percentageElement.textContent).toBe("50%")
  })

  test("shows attached display when preserved attachment exists", () => {
    const fileDisplay = document.createElement("div")
    fileDisplay.classList.add("hidden")
    element.appendChild(fileDisplay)
    Object.defineProperty(controller, 'fileDisplayTarget', { value: fileDisplay, writable: false })

    const hiddenSignedId = document.createElement("input")
    hiddenSignedId.type = "hidden"
    hiddenSignedId.name = "signed_id"
    hiddenSignedId.value = "preserved_blob_123"
    element.appendChild(hiddenSignedId)

    controller.connect()

    expect(fileDisplay.classList.contains("hidden")).toBe(false)
    expect(fileInput.classList.contains("hidden")).toBe(true)
  })

  test("removes file, aborts running upload, and clears signed_id field", () => {
    const fileDisplay = document.createElement("div")
    element.appendChild(fileDisplay)
    Object.defineProperty(controller, 'fileDisplayTarget', { value: fileDisplay, writable: false })

    const hiddenSignedId = document.createElement("input")
    hiddenSignedId.type = "hidden"
    hiddenSignedId.name = "signed_id"
    hiddenSignedId.value = "signed_blob_abc"
    element.appendChild(hiddenSignedId)

    const mockXHR = {
      abort: jest.fn(),
      upload: { addEventListener: jest.fn() }
    }
    controller.cancelToken = mockXHR
    controller.uploadInProgress = true

    controller.removeFile()

    expect(mockXHR.abort).toHaveBeenCalled()
    expect(hiddenSignedId.value).toBe("")
    expect(fileDisplay.classList.contains("hidden")).toBe(true)
    expect(fileInput.classList.contains("hidden")).toBe(false)
    expect(controller.uploadInProgress).toBe(false)
  })

  test("deduplicates hidden signed_id input on repeated upload success", () => {
    const file1 = new File(["1"], "doc1.pdf", { type: "application/pdf" })
    const file2 = new File(["2"], "doc2.pdf", { type: "application/pdf" })

    controller.handleUploadSuccess({ signed_id: "blob_1" }, file1, 1)
    controller.handleUploadSuccess({ signed_id: "blob_2" }, file2, 2)

    const inputs = element.querySelectorAll('input[type="hidden"][name="signed_id"]')
    expect(inputs.length).toBe(1)
    expect(inputs[0].value).toBe("blob_2")
  })

  describe("superseded upload callbacks", () => {
    let callbacks

    beforeEach(() => {
      // Hold each upload's completion so the test controls the order uploads finish in
      callbacks = []
      DirectUpload.mockImplementation(() => ({
        create: jest.fn((callback) => callbacks.push(callback))
      }))
    })

    const selectFile = (name) => {
      controller.handleFileSelect({ target: { files: [new File([name], name, { type: "application/pdf" })] } })
    }
    const signedIdInputs = () => element.querySelectorAll('input[type="hidden"][name="signed_id"]')

    test("ignores an older upload that finishes after the newer one", () => {
      selectFile("older.pdf")
      selectFile("newer.pdf")

      callbacks[1](null, { signed_id: "newer_blob" })
      callbacks[0](null, { signed_id: "older_blob" })

      expect(signedIdInputs().length).toBe(1)
      expect(signedIdInputs()[0].value).toBe("newer_blob")
      expect(submitButton.disabled).toBe(false)
    })

    test("ignores an older upload's success or failure while the newer one is still running", () => {
      selectFile("older.pdf")
      selectFile("newer.pdf")

      callbacks[0](null, { signed_id: "older_blob" })
      expect(signedIdInputs().length).toBe(0)
      expect(submitButton.disabled).toBe(true)

      const consoleError = jest.spyOn(console, "error").mockImplementation(() => {})
      callbacks[0](new Error("older failed"))
      expect(consoleError).not.toHaveBeenCalled() // handleUploadError always logs, so it never ran
      expect(submitButton.disabled).toBe(true)
      consoleError.mockRestore()

      callbacks[1](null, { signed_id: "newer_blob" })
      expect(signedIdInputs()[0].value).toBe("newer_blob")
      expect(submitButton.disabled).toBe(false)
    })

    test("does not reattach a file removed while its upload was running", () => {
      selectFile("removed.pdf")
      controller.removeFile()

      callbacks[0](null, { signed_id: "late_blob" })

      const values = Array.from(signedIdInputs()).map(input => input.value)
      expect(values).not.toContain("late_blob")
    })
  })

  describe("filename field", () => {
    test("does not create a nameless field when no filename param name is configured", () => {
      const filenameTarget = document.createElement("input")
      filenameTarget.type = "hidden"
      element.appendChild(filenameTarget)
      Object.defineProperty(controller, 'filenameTarget', { value: filenameTarget, writable: false })

      controller.handleUploadSuccess({ signed_id: "blob_1" }, new File(["1"], "doc.pdf", { type: "application/pdf" }), 1)

      // Only the filename target and the signed_id field; no extra field for a missing name
      expect(element.querySelectorAll('input[type="hidden"]').length).toBe(2)
      expect(element.querySelectorAll('input[type="hidden"][name="signed_id"]').length).toBe(1)
      expect(filenameTarget.value).toBe("")
    })

    test("records the filename in the configured field", () => {
      Object.defineProperty(controller, 'hasFilenameParamNameValue', { value: true, writable: false })
      Object.defineProperty(controller, 'filenameParamNameValue', { value: "proof_filename", writable: false })

      controller.handleUploadSuccess({ signed_id: "blob_1" }, new File(["1"], "doc.pdf", { type: "application/pdf" }), 1)

      const fields = element.querySelectorAll('input[type="hidden"][name="proof_filename"]')
      expect(fields.length).toBe(1)
      expect(fields[0].value).toBe("doc.pdf")
    })
  })
})
