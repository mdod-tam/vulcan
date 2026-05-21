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
  static targets = ["input", "progress", "percentage", "cancel", "submit"]
  static values = {
    directUploadUrl: String,
    allowedTypes: Array,
    invalidTypeMessage: String,
    maxFileSize: Number
  }

  connect() {
    this.cancelToken = null
    this.uploadInProgress = false
  }

  handleFileSelect(event) {
    const file = event.target.files[0]
    if (!file) return

    if (!this.validateFile(file)) {
      return
    }

    this.progressTarget.classList.remove("hidden")
    this.cancelTarget.classList.remove("hidden")
    this.submitTarget.disabled = true
    this.uploadInProgress = true
    this.uploadFile(file)
  }

  validateFile(file) {
    const maxFileSize = this.maxFileSizeValue || (5 * 1024 * 1024)

    if (!this.isAllowedFileType(file)) {
      const errorMessage = this.invalidTypeMessageValue ||
        "Invalid file type. Please upload a PDF or an image file (PDF, JPEG, PNG, or HEIC/HEIF)."
      this.showNotification(errorMessage, "error")
      this.inputTarget.value = ""
      return false
    }

    if (file.size > maxFileSize) {
      const maxMb = Math.round(maxFileSize / (1024 * 1024))
      const errorMessage = `File is too large. Maximum size allowed is ${maxMb}MB.`
      this.showNotification(errorMessage, "error")
      this.inputTarget.value = ""
      return false
    }

    return true
  }

  isAllowedFileType(file) {
    if (this.allowedTypesValue.includes(file.type)) return true

    const extension = file.name.split(".").pop()?.toLowerCase()
    const mimeFromExtension = EXTENSION_TO_MIME[extension]
    return mimeFromExtension && this.allowedTypesValue.includes(mimeFromExtension)
  }

  uploadFile(file) {
    const upload = new DirectUpload(file, this.directUploadUrlValue, this)

    upload.create((error, blob) => {
      if (error) {
        this.handleUploadError(error)
      } else {
        this.handleUploadSuccess(blob)
      }
    })
  }

  directUploadWillStoreFileWithXHR(xhr) {
    this.cancelToken = xhr
    xhr.upload.addEventListener("progress", event => this.updateProgress(event))
  }

  updateProgress(event) {
    if (event.lengthComputable) {
      const percent = Math.round((event.loaded / event.total) * 100)
      this.progressTarget.querySelector("[role=progressbar]").style.width = `${percent}%`
      this.percentageTarget.textContent = `${percent}%`
    }
  }

  cancelUpload() {
    if (this.cancelToken && this.uploadInProgress) {
      this.cancelToken.abort()
      this.resetUpload()
      this.inputTarget.value = ""
    }
  }

  handleUploadError(error) {
    console.error("Upload error:", error)
    const errorMessage = "There was an error uploading your file. Please try again."
    this.showNotification(errorMessage, "error")
    this.resetUpload()
  }

  handleUploadSuccess(blob) {
    const hiddenField = document.createElement("input")
    hiddenField.setAttribute("type", "hidden")
    hiddenField.setAttribute("name", this.inputTarget.name)
    hiddenField.setAttribute("value", blob.signed_id)
    this.element.appendChild(hiddenField)

    this.progressTarget.querySelector("[role=progressbar]").style.width = "100%"
    this.percentageTarget.textContent = "100%"
    this.submitTarget.disabled = false
    this.uploadInProgress = false

    setTimeout(() => {
      this.progressTarget.classList.add("hidden")
      this.cancelTarget.classList.add("hidden")
    }, 1000)
  }

  resetUpload() {
    this.progressTarget.querySelector("[role=progressbar]").style.width = "0%"
    this.percentageTarget.textContent = "0%"
    this.progressTarget.classList.add("hidden")
    this.cancelTarget.classList.add("hidden")
    this.submitTarget.disabled = false
    this.uploadInProgress = false
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
