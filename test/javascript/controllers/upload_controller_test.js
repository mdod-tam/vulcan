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
})
