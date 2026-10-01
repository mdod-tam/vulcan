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

  test("deduplicates hidden signed_id input on repeated upload success", () => {
    controller.handleUploadSuccess({ signed_id: "blob_1" }, 1)
    controller.handleUploadSuccess({ signed_id: "blob_2" }, 2)

    const inputs = element.querySelectorAll('input[type="hidden"][name="signed_id"]')
    expect(inputs.length).toBe(1)
    expect(inputs[0].value).toBe("blob_2")
  })
  describe("request lifecycle", () => {
    let attempts

    // Each DirectUpload records its delegate and completion callback so tests drive every phase
    beforeEach(() => {
      attempts = []
      DirectUpload.mockImplementation((file, url, delegate) => {
        const attempt = { delegate, callback: null }
        attempts.push(attempt)
        return { create: jest.fn((callback) => { attempt.callback = callback }) }
      })
    })

    afterEach(() => {
      jest.useRealTimers()
    })

    const fakeXHR = () => {
      const listeners = {}
      const uploadListeners = {}
      return {
        abort: jest.fn(),
        addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
        upload: { addEventListener: (type, fn) => { (uploadListeners[type] ||= []).push(fn) } },
        start() { (listeners.loadstart || []).forEach(fn => fn()) },
        progress(loaded, total) {
          (uploadListeners.progress || []).forEach(fn => fn({ lengthComputable: true, loaded, total }))
        }
      }
    }

    const selectFile = (name) => {
      controller.handleFileSelect({ target: { files: [new File([name], name, { type: "application/pdf" })] } })
    }
    const signedIdInputs = () => element.querySelectorAll('input[type="hidden"][name="signed_id"]')
    const percentage = () => element.querySelector("[data-upload-target='percentage']").textContent
    const expectIdle = () => {
      expect(submitButton.disabled).toBe(false)
      expect(progressBar.classList.contains("hidden")).toBe(true)
      expect(cancelButton.classList.contains("hidden")).toBe(true)
    }

    test("cancel before any request starts clears busy state and blocks the attempt's later requests", () => {
      selectFile("doc.pdf")
      expect(submitButton.disabled).toBe(true)

      controller.cancelUpload()
      expectIdle()

      // The checksum finishes after the cancel and the attempt announces its blob request
      const blobRequest = fakeXHR()
      attempts[0].delegate.directUploadWillCreateBlobWithXHR(blobRequest)
      blobRequest.start()
      expect(blobRequest.abort).toHaveBeenCalled()

      attempts[0].callback(null, { signed_id: "cancelled_blob" })
      expect(signedIdInputs().length).toBe(0)
      expectIdle()
    })

    test("cancel while the blob record is being created aborts that request", () => {
      selectFile("doc.pdf")
      const blobRequest = fakeXHR()
      attempts[0].delegate.directUploadWillCreateBlobWithXHR(blobRequest)

      controller.cancelUpload()

      expect(blobRequest.abort).toHaveBeenCalled()
      expectIdle()
      attempts[0].callback(null, { signed_id: "cancelled_blob" })
      expect(signedIdInputs().length).toBe(0)
    })

    test("cancel while the file is being stored aborts the storage request", () => {
      selectFile("doc.pdf")
      attempts[0].delegate.directUploadWillCreateBlobWithXHR(fakeXHR())
      const storageRequest = fakeXHR()
      attempts[0].delegate.directUploadWillStoreFileWithXHR(storageRequest)

      controller.cancelUpload()

      expect(storageRequest.abort).toHaveBeenCalled()
      expectIdle()
      expect(fileInput.value).toBe("")
    })

    test("a new selection after a cancel uploads and can be submitted", () => {
      selectFile("first.pdf")
      controller.cancelUpload()

      selectFile("second.pdf")
      expect(submitButton.disabled).toBe(true)
      attempts[1].callback(null, { signed_id: "second_blob" })

      expect(signedIdInputs().length).toBe(1)
      expect(signedIdInputs()[0].value).toBe("second_blob")
      expect(submitButton.disabled).toBe(false)
    })

    test("a newer selection aborts the running request and ignores the older attempt's progress", () => {
      selectFile("older.pdf")
      const olderBlobRequest = fakeXHR()
      attempts[0].delegate.directUploadWillCreateBlobWithXHR(olderBlobRequest)

      selectFile("newer.pdf")
      expect(olderBlobRequest.abort).toHaveBeenCalled()

      // The older attempt still reaches storage; that request is stopped and its progress ignored
      const olderStorageRequest = fakeXHR()
      attempts[0].delegate.directUploadWillStoreFileWithXHR(olderStorageRequest)
      olderStorageRequest.start()
      expect(olderStorageRequest.abort).toHaveBeenCalled()
      olderStorageRequest.progress(90, 100)
      expect(percentage()).toBe("0%")

      const newerStorageRequest = fakeXHR()
      attempts[1].delegate.directUploadWillStoreFileWithXHR(newerStorageRequest)
      newerStorageRequest.progress(40, 100)
      expect(percentage()).toBe("40%")
    })

    test("ignores an older upload that finishes after the newer one", () => {
      selectFile("older.pdf")
      selectFile("newer.pdf")

      attempts[1].callback(null, { signed_id: "newer_blob" })
      attempts[0].callback(null, { signed_id: "older_blob" })

      expect(signedIdInputs().length).toBe(1)
      expect(signedIdInputs()[0].value).toBe("newer_blob")
      expect(submitButton.disabled).toBe(false)
    })

    test("ignores an older upload's success or failure while the newer one is still running", () => {
      selectFile("older.pdf")
      selectFile("newer.pdf")

      attempts[0].callback(null, { signed_id: "older_blob" })
      expect(signedIdInputs().length).toBe(0)
      expect(submitButton.disabled).toBe(true)

      const consoleError = jest.spyOn(console, "error").mockImplementation(() => {})
      attempts[0].callback(new Error("older failed"))
      expect(consoleError).not.toHaveBeenCalled() // handleUploadError always logs, so it never ran
      expect(submitButton.disabled).toBe(true)
      consoleError.mockRestore()

      attempts[1].callback(null, { signed_id: "newer_blob" })
      expect(signedIdInputs()[0].value).toBe("newer_blob")
      expect(submitButton.disabled).toBe(false)
    })

    test("the hide timer from a finished upload leaves a newer upload's indicators visible", () => {
      jest.useFakeTimers()
      selectFile("first.pdf")
      attempts[0].callback(null, { signed_id: "first_blob" })

      selectFile("second.pdf")
      jest.advanceTimersByTime(1000)

      expect(progressBar.classList.contains("hidden")).toBe(false)
      expect(cancelButton.classList.contains("hidden")).toBe(false)
      expect(submitButton.disabled).toBe(true)
    })

    test("the hide timer clears the indicators after an upload completes", () => {
      jest.useFakeTimers()
      selectFile("doc.pdf")
      attempts[0].callback(null, { signed_id: "blob" })

      jest.advanceTimersByTime(1000)

      expectIdle()
    })
  })
})
