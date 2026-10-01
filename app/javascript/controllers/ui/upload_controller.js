import { Controller } from "@hotwired/stimulus"
import { DirectUpload } from "@rails/activestorage"

const EXTENSION_TO_MIME = {
  pdf: "application/pdf",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  heic: "image/heic",
  heif: "image/heif"
}

export default class extends Controller {
  static targets = [
    "input",
    "progress",
    "percentage",
    "cancel",
    "submit",
    "fileDisplay",
    "filenameDisplay",
    "signedId",
    "filename"
  ]
  static values = {
    directUploadUrl: String,
    allowedTypes: Array,
    invalidTypeMessage: String,
    maxFileSize: Number,
    signedIdParamName: String,
    filenameParamName: String
  }

  connect() {
    this.cancelToken = null
    this.uploadInProgress = false
    this.activeUploadId = 0

    // If an existing signed_id is present (e.g. from validation re-render), show the display pane
    if (this.hasPreservedAttachment()) {
      this.showAttachedDisplay()
    }
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

  hasPreservedAttachment() {
    const signedInput = this.findSignedIdField()
    return signedInput && Boolean(signedInput.value && signedInput.value.trim())
  }

  showAttachedDisplay() {
    const fileDisplay = this.targetOrNull("fileDisplay")
    const input = this.targetOrNull("input")
    if (fileDisplay) {
      fileDisplay.classList.remove("hidden")
      if (input) {
        input.classList.add("hidden")
      }
    }
  }

  handleFileSelect(event) {
    const file = event.target.files[0]
    if (!file) return

    if (!this.validateFile(file)) {
      return
    }

    this.activeUploadId += 1
    const currentUploadId = this.activeUploadId

    const progress = this.targetOrNull("progress")
    const cancel = this.targetOrNull("cancel")
    if (progress) progress.classList.remove("hidden")
    if (cancel) cancel.classList.remove("hidden")
    this.uploadInProgress = true
    this.element.dataset.uploadInProgress = "true"
    this.updateSubmitState()

    this.dispatchFormEvent("upload:start", { file: file.name, uploadId: currentUploadId })
    this.uploadFile(file, currentUploadId)
  }

  validateFile(file) {
    const maxFileSize = this.maxFileSizeValue || (5 * 1024 * 1024)
    const input = this.targetOrNull("input")

    if (!this.isAllowedFileType(file)) {
      const errorMessage = this.invalidTypeMessageValue ||
        "Invalid file type. Please upload a PDF or an image file (PDF, JPEG, PNG, or HEIC/HEIF)."
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
    const upload = new DirectUpload(file, this.directUploadUrlValue, this)

    upload.create((error, blob) => {
      // Discard late completion if this upload was superseded, cancelled, or removed
      if (uploadId !== this.activeUploadId) {
        return
      }

      if (error) {
        this.handleUploadError(error)
      } else {
        this.handleUploadSuccess(blob, file, uploadId)
      }
    })
  }

  directUploadWillStoreFileWithXHR(xhr) {
    this.cancelToken = xhr
    xhr.upload.addEventListener("progress", event => this.updateProgress(event))
  }

  updateProgress(event) {
    const progress = this.targetOrNull("progress")
    const percentage = this.targetOrNull("percentage")
    if (event.lengthComputable && progress && percentage) {
      const percent = Math.round((event.loaded / event.total) * 100)
      const progressBar = progress.querySelector("[role=progressbar]")
      if (progressBar) progressBar.style.width = `${percent}%`
      percentage.textContent = `${percent}%`
    }
  }

  cancelUpload() {
    this.activeUploadId += 1
    if (this.cancelToken && this.uploadInProgress) {
      this.cancelToken.abort()
      this.resetUpload()
      const input = this.targetOrNull("input")
      if (input) input.value = ""
    }
  }

  removeFile() {
    // Invalidate any running upload so a late callback cannot reattach
    this.activeUploadId += 1
    if (this.cancelToken && this.uploadInProgress) {
      this.cancelToken.abort()
    }

    this.clearSignedIdField()
    this.clearFilenameField()

    const input = this.targetOrNull("input")
    if (input) {
      input.value = ""
      input.classList.remove("hidden")
    }

    const fileDisplay = this.targetOrNull("fileDisplay")
    if (fileDisplay) {
      fileDisplay.classList.add("hidden")
    }

    this.resetUpload()
    this.dispatchFormEvent("upload:removed")
  }

  replaceFile() {
    const input = this.targetOrNull("input")
    if (input) {
      input.classList.remove("hidden")
      input.click()
    }
  }

  handleUploadError(error) {
    console.error("Upload error:", error)
    const errorMessage = "There was an error uploading your file. Please try again."
    this.showNotification(errorMessage, "error")
    this.resetUpload()
  }

  handleUploadSuccess(blob, file, uploadId) {
    // Ensure only one signed_id input exists with the current value
    const signedField = this.ensureSignedIdField()
    signedField.value = blob.signed_id

    // Also record filename for display preservation across renders if configured
    const filenameField = this.ensureFilenameField()
    if (filenameField) filenameField.value = file.name

    const filenameDisplay = this.targetOrNull("filenameDisplay")
    if (filenameDisplay) {
      filenameDisplay.textContent = file.name
    }

    const fileDisplay = this.targetOrNull("fileDisplay")
    const input = this.targetOrNull("input")
    if (fileDisplay) {
      fileDisplay.classList.remove("hidden")
      if (input) {
        input.classList.add("hidden")
      }
    }

    const progress = this.targetOrNull("progress")
    const percentage = this.targetOrNull("percentage")
    if (progress && percentage) {
      const progressBar = progress.querySelector("[role=progressbar]")
      if (progressBar) progressBar.style.width = "100%"
      percentage.textContent = "100%"
    }

    this.uploadInProgress = false
    delete this.element.dataset.uploadInProgress
    this.updateSubmitState()

    const cancel = this.targetOrNull("cancel")
    setTimeout(() => {
      if (progress) progress.classList.add("hidden")
      if (cancel) cancel.classList.add("hidden")
    }, 1000)

    this.dispatchFormEvent("upload:complete", { signedId: blob.signed_id, filename: file.name, uploadId })
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
    if (this.targetOrNull("signedId")) {
      hiddenField.setAttribute("data-upload-target", "signedId")
    }
    this.element.appendChild(hiddenField)
    return hiddenField
  }

  findSignedIdField() {
    const signedId = this.targetOrNull("signedId")
    if (signedId) return signedId
    const fieldName = this.signedIdFieldName
    return this.element.querySelector(`input[type="hidden"][name="${fieldName}"]`)
  }

  clearSignedIdField() {
    const fieldName = this.signedIdFieldName
    const existing = this.element.querySelectorAll(`input[type="hidden"][name="${fieldName}"]`)
    existing.forEach(el => {
      el.value = ""
    })
    const signedId = this.targetOrNull("signedId")
    if (signedId) {
      signedId.value = ""
    }
  }

  // Returns null when no field name is configured; a nameless field would never be submitted
  ensureFilenameField() {
    const fieldName = this.filenameFieldName
    if (!fieldName) return null

    const existingFields = Array.from(this.element.querySelectorAll(`input[type="hidden"][name="${fieldName}"]`))

    if (existingFields.length > 0) {
      existingFields.slice(1).forEach(el => el.remove())
      return existingFields[0]
    }

    const hiddenField = document.createElement("input")
    hiddenField.setAttribute("type", "hidden")
    hiddenField.setAttribute("name", fieldName)
    if (this.targetOrNull("filename")) {
      hiddenField.setAttribute("data-upload-target", "filename")
    }
    this.element.appendChild(hiddenField)
    return hiddenField
  }

  clearFilenameField() {
    const fieldName = this.filenameFieldName
    if (!fieldName) return
    const existing = this.element.querySelectorAll(`input[type="hidden"][name="${fieldName}"]`)
    existing.forEach(el => {
      el.value = ""
    })
    const filename = this.targetOrNull("filename")
    if (filename) {
      filename.value = ""
    }
  }

  get signedIdFieldName() {
    if (this.hasSignedIdParamNameValue && this.signedIdParamNameValue) return this.signedIdParamNameValue
    const input = this.targetOrNull("input")
    return (input && input.name) ? input.name : "signed_id"
  }

  get filenameFieldName() {
    if (this.hasFilenameParamNameValue && this.filenameParamNameValue) return this.filenameParamNameValue
    const filename = this.targetOrNull("filename")
    return (filename && filename.name) ? filename.name : null
  }

  resetUpload() {
    const progress = this.targetOrNull("progress")
    const percentage = this.targetOrNull("percentage")
    if (progress && percentage) {
      const progressBar = progress.querySelector("[role=progressbar]")
      if (progressBar) progressBar.style.width = "0%"
      percentage.textContent = "0%"
      progress.classList.add("hidden")
    }
    const cancel = this.targetOrNull("cancel")
    if (cancel) cancel.classList.add("hidden")
    this.uploadInProgress = false
    delete this.element.dataset.uploadInProgress
    this.updateSubmitState()
  }

  updateSubmitState() {
    const form = this.element.closest("form") || (this.element.tagName === "FORM" ? this.element : null)
    const formInProgress = form && form.dataset.uploadInProgress === "true"
    const descendantInProgress = form ? form.querySelectorAll('[data-upload-in-progress="true"]').length > 0 : false
    const anyInProgress = Boolean(formInProgress || descendantInProgress || this.uploadInProgress)

    const submitBtn = this.resolveSubmitButton(form)
    if (submitBtn) {
      submitBtn.disabled = anyInProgress
    }
  }

  resolveSubmitButton(form) {
    const submit = this.targetOrNull("submit")
    if (submit) return submit
    if (form) {
      return form.querySelector('button[type="submit"], input[type="submit"]')
    }
    return null
  }

  dispatchFormEvent(eventName, detail = {}) {
    const event = new CustomEvent(eventName, {
      bubbles: true,
      cancelable: true,
      detail: { controller: this, ...detail }
    })
    this.element.dispatchEvent(event)
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
