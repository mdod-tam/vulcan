import { Controller } from "@hotwired/stimulus"
import { DirectUpload } from "@rails/activestorage"

const EXTENSION_TO_MIME = {
  pdf: "application/pdf",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  heic: "image/heic",
  heif: "image/heif",
  tif: "image/tiff",
  tiff: "image/tiff"
}

export default class extends Controller {
  static targets = ["input", "progress", "percentage", "cancel", "submit"]
  static values = {
    directUploadUrl: String,
    allowedTypes: Array,
    invalidTypeMessage: String,
    maxFileSize: Number
  }

  connect() {
    this.currentRequest = null
    this.uploadInProgress = false
    // Each selection is one attempt; callbacks from any other attempt are ignored
    this.activeUploadId = 0
  }

  targetOrNull(name) {
    const hasTarget = `has${name.charAt(0).toUpperCase() + name.slice(1)}Target`
    if (this[hasTarget] !== undefined) {
      return this[hasTarget] ? this[`${name}Target`] : null
    }
    try {
      return this[`${name}Target`] || null
    } catch {
      return null
    }
  }

  handleFileSelect(event) {
    const file = event.target.files[0]
    if (!file) return

    if (!this.validateFile(file)) {
      return
    }

    // A new selection supersedes any upload still running
    if (this.uploadInProgress) this.abortCurrentRequest()

    this.activeUploadId += 1
    const uploadId = this.activeUploadId

    const progress = this.targetOrNull("progress")
    const cancel = this.targetOrNull("cancel")
    if (progress) progress.classList.remove("hidden")
    if (cancel) cancel.classList.remove("hidden")
    this.setProgress(0)
    this.uploadInProgress = true
    this.updateSubmitState()

    this.uploadFile(file, uploadId)
  }

  validateFile(file) {
    const maxFileSize = this.maxFileSizeValue || (5 * 1024 * 1024)
    const input = this.targetOrNull("input")

    if (!this.isAllowedFileType(file)) {
      const errorMessage = this.invalidTypeMessageValue ||
        "Invalid file type. Please upload a PDF or an image file (PDF, JPEG, PNG, TIFF, or HEIC/HEIF)."
      this.showNotification(errorMessage, "error")
      if (input) input.value = ""
      return false
    }

    if (file.size > maxFileSize) {
      const maxMb = Math.round(maxFileSize / (1024 * 1024))
      const errorMessage = `File is too large. Maximum size allowed is ${maxMb}MB.`
      this.showNotification(errorMessage, "error")
      if (input) input.value = ""
      return false
    }

    return true
  }

  isAllowedFileType(file) {
    if (!this.allowedTypesValue || this.allowedTypesValue.length === 0) return true
    if (this.allowedTypesValue.includes(file.type)) return true

    const extension = file.name.split(".").pop()?.toLowerCase()
    const mimeFromExtension = EXTENSION_TO_MIME[extension]
    return Boolean(mimeFromExtension && this.allowedTypesValue.includes(mimeFromExtension))
  }

  uploadFile(file, uploadId) {
    // One delegate per attempt, so request hooks and progress stay tied to the attempt that made them
    const delegate = {
      directUploadWillCreateBlobWithXHR: xhr => this.trackRequest(xhr, uploadId),
      directUploadWillStoreFileWithXHR: xhr => {
        this.trackRequest(xhr, uploadId)
        xhr.upload.addEventListener("progress", event => {
          if (uploadId === this.activeUploadId) this.updateProgress(event)
        })
      }
    }

    new DirectUpload(file, this.directUploadUrlValue, delegate).create((error, blob) => {
      // Discard late completion if this upload was superseded or cancelled
      if (uploadId !== this.activeUploadId) return

      this.currentRequest = null
      if (error) {
        this.handleUploadError(error)
      } else {
        this.handleUploadSuccess(blob, uploadId)
      }
    })
  }

  // Active Storage announces each request before sending it, when abort() has no effect,
  // so a request from a cancelled or superseded attempt is aborted once it starts
  trackRequest(xhr, uploadId) {
    if (uploadId === this.activeUploadId) {
      this.currentRequest = xhr
    } else {
      xhr.addEventListener("loadstart", () => xhr.abort())
    }
  }

  abortCurrentRequest() {
    if (this.currentRequest) this.currentRequest.abort()
    this.currentRequest = null
  }

  updateProgress(event) {
    if (event.lengthComputable) {
      this.setProgress(Math.round((event.loaded / event.total) * 100))
    }
  }

  setProgress(percent) {
    const progress = this.targetOrNull("progress")
    const percentage = this.targetOrNull("percentage")
    if (!progress || !percentage) return

    const progressBar = progress.querySelector("[role=progressbar]")
    if (progressBar) progressBar.style.width = `${percent}%`
    percentage.textContent = `${percent}%`
  }

  cancelUpload() {
    if (!this.uploadInProgress) return

    // Invalidate the attempt first so nothing it started can complete afterwards,
    // whether it is computing the checksum, creating the blob, or storing the file
    this.activeUploadId += 1
    this.abortCurrentRequest()
    this.resetUpload()
    const input = this.targetOrNull("input")
    if (input) input.value = ""
  }

  handleUploadError(error) {
    console.error("Upload error:", error)
    const errorMessage = "There was an error uploading your file. Please try again."
    this.showNotification(errorMessage, "error")
    this.resetUpload()
  }

  handleUploadSuccess(blob, uploadId) {
    // Ensure only one signed_id input exists with the current value
    const signedField = this.ensureSignedIdField()
    signedField.value = blob.signed_id

    this.setProgress(100)
    this.uploadInProgress = false
    this.updateSubmitState()

    setTimeout(() => {
      // Leave the indicators alone if a newer attempt has started since
      if (uploadId !== this.activeUploadId || this.uploadInProgress) return

      const progress = this.targetOrNull("progress")
      const cancel = this.targetOrNull("cancel")
      if (progress) progress.classList.add("hidden")
      if (cancel) cancel.classList.add("hidden")
    }, 1000)
  }

  ensureSignedIdField() {
    const fieldName = this.signedIdFieldName
    // Find any existing signed ID fields within this element
    const existingFields = Array.from(this.element.querySelectorAll(`input[type="hidden"][name="${fieldName}"]`))

    if (existingFields.length > 0) {
      // Remove any extra duplicates, keeping the first
      existingFields.slice(1).forEach(el => el.remove())
      return existingFields[0]
    }

    const hiddenField = document.createElement("input")
    hiddenField.setAttribute("type", "hidden")
    hiddenField.setAttribute("name", fieldName)
    this.element.appendChild(hiddenField)
    return hiddenField
  }

  get signedIdFieldName() {
    const input = this.targetOrNull("input")
    return (input && input.name) ? input.name : "signed_id"
  }

  resetUpload() {
    this.setProgress(0)
    const progress = this.targetOrNull("progress")
    if (progress) progress.classList.add("hidden")
    const cancel = this.targetOrNull("cancel")
    if (cancel) cancel.classList.add("hidden")
    this.uploadInProgress = false
    this.updateSubmitState()
  }

  updateSubmitState() {
    const submit = this.targetOrNull("submit")
    if (submit) submit.disabled = this.uploadInProgress
  }

  showNotification(message, type = "info") {
    const flashRoot = document.getElementById("flash")
    if (!flashRoot) {
      if (process.env.NODE_ENV !== "production") {
        console.warn("Flash container not found; message:", message)
      }
      return
    }

    let wrapper = flashRoot.querySelector(".flash-messages")
    if (!wrapper) {
      wrapper = document.createElement("div")
      wrapper.className = "flash-messages"
      wrapper.setAttribute("aria-live", "polite")
      flashRoot.innerHTML = ""
      flashRoot.appendChild(wrapper)
    }

    const msg = document.createElement("div")
    msg.setAttribute("role", "alert")
    msg.className = `flash-message flash-${type} mb-4`
    msg.textContent = message
    wrapper.appendChild(msg)
  }
}
