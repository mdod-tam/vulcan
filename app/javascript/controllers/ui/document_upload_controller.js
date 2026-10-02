import { Controller } from "@hotwired/stimulus"

// Browsers report an empty or generic type for some files, notably HEIC and TIFF, so the
// extension stands in when the reported type is not allowed.
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
 * The one document upload control (rendered by shared/_document_upload.html.erb).
 *
 * Rails direct-uploads the chosen file when its form is submitted, inserting a hidden input named like
 * the file input that carries the new signed ID, and fires direct-upload:* events on the input. This
 * controller gives immediate type and size feedback on selection, shows progress, and lets a person
 * cancel. The retained upload from an earlier attempt stays in the submission even after a new upload
 * finishes: storage accepting a file is not the server accepting it, and the server prefers the new
 * upload while it can fall back to the retained one if it refuses the new one. A reference completed in
 * an earlier, interrupted submission is kept until a new upload succeeds and then becomes the retained
 * upload, so the same fallback covers it. Remove clears every
 * pending reference this control owns; it never deletes a stored document. Form-wide submit gating
 * stays with the form's own controller, which listens for direct-uploads:start/end.
 */
export default class extends Controller {
  static targets = ["input", "retained", "status", "progress", "remove", "cancel"]

  static values = {
    allowedTypes: Array,
    retainedName: String,
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
      this.statusTarget.textContent = refusal
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
    // A reference completed in an earlier attempt is kept until this attempt's upload succeeds
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
    // Active Storage handles network errors but does not listen for aborts, so an abort is
    // reported as an error and Rails stops the submission and re-enables the form.
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

    // An upload completed in an interrupted submission becomes the retained upload, so the server
    // can still fall back to it if it refuses this one
    const earlier = earlierReferences.filter(input => input.value).pop()
    if (earlier) this.retain(earlier.value)
    earlierReferences.forEach(input => input.remove())
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
    this.statusTarget.textContent = ""
    this.removeTarget.hidden = true
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  retain(signedId) {
    const [retained, ...extra] = this.retainedTargets
    extra.forEach(input => input.remove())
    if (retained) {
      retained.value = signedId
      return
    }
    const input = document.createElement("input")
    Object.assign(input, { type: "hidden", name: this.retainedNameValue, value: signedId })
    input.dataset.documentUploadTarget = "retained"
    this.element.append(input)
  }

  // The hidden signed-ID inputs Rails added for this control's completed uploads
  uploadedReferences() {
    return Array.from(this.element.querySelectorAll('input[type="hidden"]'))
      .filter(input => input.name === this.inputTarget.name)
  }

  // Remove is offered only when there is a chosen file or a retained upload to clear
  showRemove() {
    this.removeTarget.hidden = !(this.inputTarget.files?.length || this.hasRetainedTarget)
  }

  fill(text, filename) {
    return text.replace("%{filename}", filename || "")
  }
}
