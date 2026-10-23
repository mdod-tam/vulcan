import { Controller } from "@hotwired/stimulus"

const EXTENSION_TO_MIME = {
  pdf: "application/pdf", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png",
  heic: "image/heic", heif: "image/heif", tif: "image/tiff", tiff: "image/tiff"
}

// One upload control stages a private file, waits for its scan, and submits only the cleared reference.
export default class extends Controller {
  static targets = ["input", "retained", "status", "progress", "remove", "cancel", "retry"]
  static values = {
    allowedTypes: Array, retainedName: String, retainedFilename: String, maxBytes: Number,
    maxInclusive: Boolean, invalidTypeMessage: String, tooLargeMessage: String,
    uploadingText: String, uploadedText: String, canceledText: String, failedText: String,
    scanningText: String, blockedText: String, unavailableText: String, waitText: String,
    linkUnavailableText: String, sessionExpiredText: String,
    scansUrl: String, purpose: String, slot: String, context: String, secureFormType: String,
    token: String, activeSelector: String, activeValue: String, persistContext: Boolean, pollInterval: { type: Number, default: 2000 }
  }

  connect() {
    this.form = this.element.closest("form")
    this.inputTarget.dataset.documentUploadOriginalName ||= this.inputTarget.name
    this.inputTarget.dataset.documentUploadOriginallyRequired ||= String(this.inputTarget.required)
    this.originalName = this.inputTarget.dataset.documentUploadOriginalName
    this.originalRequired = this.inputTarget.dataset.documentUploadOriginallyRequired === "true"
    this.keptName = this.hasRetainedTarget ? this.retainedFilenameValue : null
    this.state = "idle"
    this.generation = (this.generation || 0) + 1
    this.discardedGenerations ||= new Set()
    this._syncActive = this.syncActive.bind(this)
    this.form?.addEventListener("change", this._syncActive)
    this._guardSubmit = this.guardSubmit.bind(this)
    this.form?.addEventListener("submit", this._guardSubmit, true)
    if (this.persistContextValue) {
      const url = new URL(window.location.href)
      url.searchParams.set("document_scan_context", this.contextValue)
      window.history.replaceState(window.history.state, "", url)
    }
    this.syncActive()
    this.restore()
  }

  disconnect() {
    this.generation += 1
    this.request?.abort()
    clearTimeout(this.pollTimer)
    this.form?.removeEventListener("submit", this._guardSubmit, true)
    this.form?.removeEventListener("change", this._syncActive)
  }

  async select() {
    const file = this.inputTarget.files[0]
    if (!file) return
    const refusal = this.refusalFor(file)
    if (refusal) {
      this.inputTarget.value = ""
      this.statusTarget.textContent = [refusal, this.keptName ? this.fill(this.uploadedTextValue, this.keptName) : ""].filter(Boolean).join(" ")
      return
    }

    this.discardedGenerations.add(this.generation)
    this.generation += 1
    const generation = this.generation
    clearTimeout(this.pollTimer)
    this.previousSelection ||= ["idle", "clean"].includes(this.state) && this.hasRetainedTarget ? {
      signedId: this.retainedTarget.value, filename: this.keptName, scanUrl: this.scanUrl
    } : null
    if (this.scanUrl && this.scanUrl !== this.previousSelection?.scanUrl) this.dismiss(this.scanUrl)
    this.scanUrl = null
    this.clearReferences()
    this.inputTarget.removeAttribute("name")
    this.keptName = file.name
    this.setState("uploading", this.fill(this.uploadingTextValue, file.name))
    const body = new FormData()
    body.append("file", file)
    Object.entries(this.scanScope()).forEach(([key, value]) => body.append(key, value))
    try {
      const data = await this.fetchJSON(this.scansUrlValue, { method: "POST", body })
      if (generation !== this.generation) {
        if (this.discardedGenerations.has(generation) && data.status_url) this.dismiss(data.status_url)
        return
      }
      this.inputTarget.value = ""
      this.applyStatus(data)
    } catch (error) {
      if (generation !== this.generation || error.name === "AbortError") return
      this.inputTarget.value = ""
      if ([422, 429].includes(error.status) && this.previousSelection) {
        const previous = this.previousSelection
        this.previousSelection = null
        this.scanUrl = previous.scanUrl
        this.keptName = previous.filename
        this.retain(previous.signedId)
        this.setState("clean", [error.userMessage, this.fill(this.uploadedTextValue, this.keptName)].filter(Boolean).join(" "))
      } else {
        this.setState("unavailable", error.userMessage || this.failedTextValue)
      }
    }
  }

  refusalFor(file) {
    const extension = file.name.split(".").pop()?.toLowerCase()
    const allowed = this.allowedTypesValue.includes(file.type) || this.allowedTypesValue.includes(EXTENSION_TO_MIME[extension])
    if (!allowed) return this.invalidTypeMessageValue
    const tooLarge = this.maxInclusiveValue ? file.size > this.maxBytesValue : file.size >= this.maxBytesValue
    return tooLarge ? this.tooLargeMessageValue : null
  }

  scanScope() {
    const scope = { purpose: this.purposeValue, slot: this.slotValue, context: this.contextValue }
    if (this.secureFormTypeValue) Object.assign(scope, { secure_form_type: this.secureFormTypeValue, token: this.tokenValue })
    return scope
  }

  async restore() {
    const generation = this.generation
    try {
      const url = new URL(this.scansUrlValue, window.location.origin)
      Object.entries(this.scanScope()).forEach(([key, value]) => url.searchParams.set(key, value))
      const data = await this.fetchJSON(url.toString())
      if (generation !== this.generation || !data?.id) return
      this.inputTarget.removeAttribute("name")
      this.applyStatus(data)
    } catch (error) {
      // A fresh form still accepts a file if there is no earlier upload to restore.
      if (generation === this.generation && (this.scanUrl || error.userMessage)) this.setState("unavailable", error.userMessage || this.unavailableTextValue)
    }
  }

  async check() {
    if (!this.scanUrl) return this.restore()
    const generation = this.generation
    try {
      const data = await this.fetchJSON(this.scanUrl)
      if (generation === this.generation) this.applyStatus(data)
    } catch (error) {
      if (generation === this.generation && error.name !== "AbortError") this.setState("unavailable", error.userMessage || this.unavailableTextValue)
    }
  }

  applyStatus(data) {
    this.dismissPreviousSelection(data.status_url)
    this.inputTarget.removeAttribute("name")
    this.scanUrl = data.status_url || this.scanUrl
    this.keptName = data.filename || this.keptName
    this.clearReferences()
    if (data.status === "clean" && data.signed_id) {
      this.retain(data.signed_id)
      this.setState("clean", this.fill(this.uploadedTextValue, this.keptName))
    } else if (["pending", "submitted", "scanning"].includes(data.status)) {
      this.setState("pending", this.fill(this.scanningTextValue, this.keptName))
      clearTimeout(this.pollTimer)
      this.pollTimer = setTimeout(() => this.check(), this.pollIntervalValue)
    } else {
      this.setState("blocked", data.message || this.blockedTextValue)
    }
  }

  setState(state, message) {
    this.state = state
    this.element.dataset.scanState = state
    this.statusTarget.textContent = message
    const waiting = ["uploading", "pending"].includes(state)
    const blocked = !["idle", "clean"].includes(state)
    this.inputTarget.setCustomValidity(blocked ? (waiting ? this.waitTextValue : message || this.waitTextValue) : "")
    this.inputTarget.required = this.originalRequired && state !== "clean"
    this.inputTarget.setAttribute("aria-required", this.inputTarget.required ? "true" : "false")
    this.progressTarget.hidden = !waiting
    this.progressTarget.removeAttribute("value")
    this.cancelTarget.hidden = state !== "uploading"
    this.removeTarget.hidden = state === "idle"
    this.removeTarget.disabled = false
    if (this.hasRetryTarget) this.retryTarget.hidden = state !== "unavailable"
    this.element.dispatchEvent(new CustomEvent("document-upload:status", { bubbles: true, detail: { state } }))
  }

  syncActive() {
    if (!this.activeSelectorValue) return
    const active = this.form?.querySelector(this.activeSelectorValue)?.value === this.activeValueValue
    this.inputTarget.disabled = !active
    this.retainedTargets.forEach(input => { input.disabled = !active })
  }

  guardSubmit(event) {
    if (this.inputTarget.disabled || ["idle", "clean"].includes(this.state)) return
    event.preventDefault()
    event.stopImmediatePropagation()
    this.inputTarget.reportValidity()
    this.inputTarget.focus()
  }

  cancel() {
    this.discardedGenerations.add(this.generation)
    this.generation += 1
    clearTimeout(this.pollTimer)
    if (this.scanUrl) this.dismiss(this.scanUrl)
    this.dismissPreviousSelection()
    this.clearReferences()
    this.inputTarget.value = ""
    this.inputTarget.name = this.originalName
    this.scanUrl = null
    this.keptName = null
    this.setState("idle", this.canceledTextValue)
  }

  remove() {
    this.cancel()
    this.statusTarget.textContent = ""
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  clearReferences() {
    this.retainedTargets.forEach(input => input.remove())
    this.element.querySelectorAll('input[type="hidden"]').forEach(input => {
      if ([this.originalName, this.retainedNameValue].includes(input.name)) input.remove()
    })
  }

  retain(signedId) {
    const input = document.createElement("input")
    Object.assign(input, { type: "hidden", name: this.originalName, value: signedId })
    input.dataset.documentUploadTarget = "retained"
    this.element.append(input)
    this.syncActive()
  }

  async dismiss(url) {
    try { await this.fetchJSON(url, { method: "DELETE" }) } catch (_) { /* Expired uploads stay private and are cleaned up. */ }
  }

  dismissPreviousSelection(currentUrl = null) {
    const previous = this.previousSelection
    this.previousSelection = null
    if (previous?.scanUrl && previous.scanUrl !== currentUrl) this.dismiss(previous.scanUrl)
  }

  async fetchJSON(url, options = {}) {
    this.request = new AbortController()
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content
    const headers = { Accept: "application/json" }
    if (csrf) headers["X-CSRF-Token"] = csrf
    const response = await fetch(url, { ...options, headers, credentials: "same-origin", signal: this.request.signal })
    const data = response.status === 204 ? null : await response.json().catch(() => null)
    if (!response.ok) {
      const error = new Error("Document scan request failed")
      error.status = response.status
      error.userMessage = data?.message
      if (response.status === 401) error.userMessage = this.sessionExpiredTextValue
      if (response.status === 404 && this.secureFormTypeValue) error.userMessage = this.linkUnavailableTextValue
      throw error
    }
    return data
  }

  fill(text, filename) { return text.replace("%{filename}", filename || "") }
}
