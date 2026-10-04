import { Controller } from "@hotwired/stimulus"

// The reported MIME type can be empty or outside the allowlist.
// Use the extension when the reported type is not allowed.
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

/**
 * Controls one document field from shared/_document_upload.html.erb.
 *
 * Rails uploads files to storage before it submits the form.
 * A completed upload does not mean the server accepted the document.
 *
 * Users can cancel or remove pending uploads. The control validates selections and shows progress.
 * The server uses retained references to rebuild a failed submission.
 * Remove clears pending references and leaves attached documents intact.
 * The form controller owns submit readiness through direct-uploads:start/end.
 */
export default class extends Controller {
  static targets = ["input", "retained", "status", "progress", "remove", "cancel"]

  static values = {
    allowedTypes: Array,
    retainedName: String,
    retainedFilename: String,
    maxBytes: Number,
    maxInclusive: Boolean,
    invalidTypeMessage: String,
    tooLargeMessage: String,
    selectedText: String,
    uploadingText: String,
    uploadedText: String,
    canceledText: String,
    failedText: String
  }

  connect() {
    this.keptName = this.hasRetainedTarget ? this.retainedFilenameValue : null
    this.form = this.element.closest("form")
    this._release = this.release.bind(this)
    this.form?.addEventListener("direct-uploads:end", this._release)
  }

  disconnect() {
    this.form?.removeEventListener("direct-uploads:end", this._release)
  }

  select() {
    const file = this.inputTarget.files[0]
    if (!file) return

    const refusal = this.refusalFor(file)
    if (refusal) {
      this.inputTarget.value = ""
      // An invalid selection leaves the pending upload unchanged.
      const kept = this.hasPendingUpload() ? this.fill(this.uploadedTextValue, this.keptName) : ""
      this.statusTarget.textContent = [refusal, kept].filter(Boolean).join(" ")
    } else {
      this.statusTarget.textContent = this.fill(this.selectedTextValue, file.name)
    }
    this.showRemove()
  }

  refusalFor(file) {
    if (!this.allowedType(file)) return this.invalidTypeMessageValue
    const tooLarge = this.maxInclusiveValue ? file.size > this.maxBytesValue : file.size >= this.maxBytesValue
    return tooLarge ? this.tooLargeMessageValue : null
  }

  allowedType(file) {
    if (this.allowedTypesValue.includes(file.type)) return true
    const extension = file.name.split(".").pop()?.toLowerCase()
    return this.allowedTypesValue.includes(EXTENSION_TO_MIME[extension])
  }

  uploadStarted() {
    // Earlier references remain available if this upload fails.
    this.earlierReferences = this.uploadedReferences()
    this.uploading = true
    this.uploadError = false
    this.uploadCanceled = false
    this.removeTarget.disabled = true
    this.cancelTarget.hidden = false
    this.progressTarget.value = 0
    this.progressTarget.hidden = false
    this.statusTarget.textContent = this.fill(this.uploadingTextValue, this.inputTarget.files[0]?.name)
  }

  rememberRequest(event) {
    const xhr = event.detail.xhr
    this.uploadXHR = xhr
    // Active Storage handles errors but does not handle aborts.
    // Treat an abort as an error so Rails stops submission and enables the form.
    xhr.addEventListener("abort", () => xhr.dispatchEvent(new Event("error")), { once: true })
    if (this.uploadCanceled) queueMicrotask(() => xhr.abort())
  }

  progress(event) {
    this.progressTarget.value = event.detail.progress
  }

  cancel() {
    this.uploadCanceled = true
    this.uploadXHR?.abort()
  }

  failed(event) {
    event.preventDefault()
    this.uploadError = true
    this.statusTarget.textContent = this.uploadCanceled ? this.canceledTextValue : this.failedTextValue
  }

  finished() {
    const name = this.inputTarget.files[0]?.name
    const earlierReferences = this.earlierReferences || []
    this.release()
    if (this.uploadError) return

    const earlier = earlierReferences.filter(input => input.value).pop()
    if (earlier) this.retain(earlier.value)
    earlierReferences.forEach(input => input.remove())
    this.keptName = name
    this.statusTarget.textContent = this.fill(this.uploadedTextValue, name)
    this.showRemove()
  }

  release() {
    if (!this.uploading) return
    this.uploading = false
    this.uploadXHR = null
    this.earlierReferences = null
    this.removeTarget.disabled = false
    this.cancelTarget.hidden = true
    this.progressTarget.hidden = true
  }

  remove() {
    if (this.uploading) return
    this.retainedTargets.forEach(input => input.remove())
    this.uploadedReferences().forEach(input => input.remove())
    this.inputTarget.value = ""
    this.keptName = null
    this.statusTarget.textContent = ""
    this.removeTarget.hidden = true
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  retain(signedId) {
    const [retained, ...extra] = this.retainedTargets
    extra.forEach(input => input.remove())
    // Keep the existing retry reference until the server validates a replacement.
    if (retained) return
    const input = document.createElement("input")
    Object.assign(input, { type: "hidden", name: this.retainedNameValue, value: signedId })
    input.dataset.documentUploadTarget = "retained"
    this.element.append(input)
  }

  // Rails adds hidden signed-ID inputs for this control's completed uploads.
  uploadedReferences() {
    return Array.from(this.element.querySelectorAll('input[type="hidden"]'))
      .filter(input => input.name === this.inputTarget.name)
  }

  // An uploaded file reference is available for the next submission.
  hasPendingUpload() {
    return this.hasRetainedTarget || this.uploadedReferences().some(input => input.value)
  }

  showRemove() {
    this.removeTarget.hidden = !(this.inputTarget.files?.length || this.hasPendingUpload())
  }

  fill(text, filename) {
    return text.replace("%{filename}", filename || "")
  }
}
