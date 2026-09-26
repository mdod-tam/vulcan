import { Controller } from "@hotwired/stimulus"
import { railsRequest } from "../../services/rails_request"
import { setVisible } from "../../utils/visibility"

const STATUS_COLORS = { saving: "text-indigo-600", saved: "text-green-600", failed: "text-red-600", unsaved: "text-red-600" }
const CONTROLS = 'input:not([type=hidden]):not([type=submit]):not([type=button]), select, textarea'

// The server orders writes by page and edit revision. Departure requests may overlap ordinary
// saves; keepalive allows them to outlive the document, but cannot guarantee delivery.
export default class extends Controller {
  static targets = ["status", "context", "revision"]
  static values = {
    url: String, debounceWait: { type: Number, default: 1000 }, formDirty: Boolean,
    savingText: String, savedText: String, failedText: String, unsavedText: String
  }

  connect() {
    this.generation = Symbol()
    this.pageContext = this.contextTarget.value
    this.revisionElement = this.revisionTarget
    this.connected = true
    this.edited = new Map()
    this.inflight = new Set()
    this.timers = new Map()
    this.initial = new Map()
    this.lastValues = new Map()
    this.manual = new Set(this.formDirtyValue ? [this.element] : [])
    this.queue = Promise.resolve()
    this.element.querySelectorAll(CONTROLS).forEach(element => {
      this.initial.set(element, fieldValue(element))
      this.lastValues.set(element.name, fieldValue(element))
      if (element.dataset.autosavePending) {
        this.edited.set(element.name, { element, value: fieldValue(element), revision: Number(element.dataset.autosavePending) })
        this.schedule(element.name, 0)
      }
    })
    this.hasChanges = this.edited.size > 0 || this.manual.size > 0
    this.onPagehide = () => this.flush()
    this.onBeforeUnload = event => { event.preventDefault(); event.returnValue = "" }
    window.addEventListener("pagehide", this.onPagehide)
    this.updateStatus()
  }

  disconnect() {
    this.connected = false
    window.removeEventListener("pagehide", this.onPagehide)
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    clearTimeout(this.statusTimer)
    this.flush()
  }

  fieldInput({ target }) { this.capture(target, this.debounceWaitValue) }
  fieldChange({ target }) { this.capture(target, 0) }
  fieldLeave({ target }) {
    if (this.edited.has(target.name)) this.schedule(target.name, 0)
  }

  capture(element, wait) {
    if (this.submitting || !element.name || element.disabled || !element.matches(CONTROLS)) return
    const value = fieldValue(element)
    this.hasChanges = true
    if (element.type === "file" || element.dataset.noAutosave) {
      if (value === this.initial.get(element)) this.manual.delete(element)
      else this.manual.add(element)
      this.formDirtyValue = this.manual.size > 0
    } else {
      if (value !== this.lastValues.get(element.name)) {
        const revision = this.nextRevision()
        this.edited.set(element.name, { element, value, revision })
        element.dataset.autosavePending = revision
        this.lastValues.set(element.name, value)
      }
      if (this.edited.has(element.name)) this.schedule(element.name, wait)
    }
    this.updateStatus()
  }

  nextRevision() {
    const revision = Number(this.revisionElement.value) + 1
    this.revisionElement.value = revision
    return revision
  }

  schedule(name, wait) {
    clearTimeout(this.timers.get(name))
    const generation = this.generation
    this.timers.set(name, setTimeout(() => {
      this.timers.delete(name)
      this.queue = this.queue.then(() => this.connected && generation === this.generation && this.save(name))
    }, wait))
  }

  async save(name) {
    const edit = this.edited.get(name)
    if (!edit || edit.sending || this.submitting) return
    const generation = this.generation
    const inflight = this.inflight
    edit.sending = true
    edit.failed = false
    inflight.add(edit)
    this.updateStatus()
    try {
      const { data } = await railsRequest.perform({
        method: "patch", url: this.urlValue, keepalive: true,
        body: { field_name: name, field_value: edit.value, autosave_context: this.pageContext, autosave_revision: edit.revision }
      })
      if (!data?.success || data.revision !== edit.revision || !Number.isSafeInteger(data.current_revision) || data.current_revision < data.revision || !["saved", "superseded"].includes(data.outcome)) {
        throw new Error("Unconfirmed autosave response")
      }
      if (generation === this.generation) {
        this.revisionElement.value = Math.max(Number(this.revisionElement.value), data.current_revision)
      }
      if (generation === this.generation && this.edited.get(name) === edit) {
        this.edited.delete(name)
        delete edit.element.dataset.autosavePending
        if (this.connected) {
          // A restored Turbo snapshot can contain an edit the server has already superseded.
          if (data.outcome === "superseded") {
            if (edit.element.type === "checkbox") edit.element.checked = data.value === true
            else edit.element.value = data.value ?? ""
            this.lastValues.set(name, fieldValue(edit.element))
            edit.element.dispatchEvent(new Event("input", { bubbles: true }))
          }
          this.clearFieldError(edit.element)
        }
      }
    } catch (error) {
      if (generation === this.generation && this.edited.get(name) === edit) {
        edit.failed = true
        const messages = error.data?.errors?.[name]
        if (messages && this.connected) this.showFieldError(edit.element, messages.join(", "))
      }
    } finally {
      edit.sending = false
      inflight.delete(edit)
      if (generation === this.generation) this.updateStatus()
    }
  }

  flush() {
    this.timers.forEach(clearTimeout)
    this.timers.clear()
    if (!this.submitting) this.edited.forEach((_edit, name) => this.save(name))
  }

  prepareSubmission() { this.nextRevision() }

  submissionStarted() {
    this.submitting = true
    this.submittedRevision = Number(this.revisionElement.value)
    this.timers.forEach(clearTimeout)
    this.timers.clear()
    // Turbo has already captured FormData. Freeze controls while that snapshot is submitted.
    this.frozen = [...this.element.querySelectorAll('input, select, textarea, button')].filter(element => !element.disabled)
    this.frozen.forEach(element => { element.disabled = true })
  }

  beforeCache() { this.frozen?.forEach(element => { element.disabled = false }) }

  submissionEnded({ detail: { success } }) {
    this.submitting = false
    this.beforeCache()
    if (success) {
      this.edited.forEach((edit, name) => {
        if (edit.revision <= this.submittedRevision) {
          this.edited.delete(name)
          this.inflight.delete(edit)
          delete edit.element.dataset.autosavePending
        }
      })
      this.manual.clear()
      this.formDirtyValue = false
    } else {
      this.edited.forEach(edit => { edit.failed = true })
      this.manual.add(this.element)
      this.formDirtyValue = true
    }
    this.updateStatus()
  }

  updateStatus() {
    if (!this.connected) return
    const failed = [...this.edited.values()].some(edit => edit.failed)
    const pending = this.edited.size > 0 || this.inflight.size > 0
    const dirty = pending || this.manual.size > 0
    if (dirty) window.addEventListener("beforeunload", this.onBeforeUnload)
    else window.removeEventListener("beforeunload", this.onBeforeUnload)
    if (!this.hasStatusTarget) return
    if (!this.hasChanges && !dirty) { this.statusTarget.textContent = ""; return }
    const state = failed ? "failed" : pending ? "saving" : this.manual.size ? "unsaved" : "saved"
    clearTimeout(this.statusTimer)
    const status = this.statusTarget
    status.classList.remove(...Object.values(STATUS_COLORS))
    status.classList.add(STATUS_COLORS[state])
    status.textContent = this[`${state}TextValue`]
    if (state === "saved") this.statusTimer = setTimeout(() => { status.textContent = "" }, 3000)
  }

  showFieldError(element, message) {
    const error = this.fieldError(element) || this.createFieldError(element)
    error.textContent = message
    setVisible(error, true)
    element.setAttribute("aria-invalid", "true")
  }

  clearFieldError(element) {
    const error = this.fieldError(element)
    if (!error) return
    error.textContent = ""
    setVisible(error, false)
    element.removeAttribute("aria-invalid")
  }

  fieldError(element) {
    const next = element.nextElementSibling
    return next?.id === fieldErrorId(element) ? next : null
  }

  createFieldError(element) {
    const error = document.createElement("p")
    error.id = fieldErrorId(element)
    error.className = "field-error-message text-red-600 text-sm mt-1"
    element.insertAdjacentElement("afterend", error)
    element.setAttribute("aria-describedby", [element.getAttribute("aria-describedby"), error.id].filter(Boolean).join(" "))
    return error
  }
}

function fieldValue(element) {
  return element.type === "checkbox" ? element.checked : element.value
}

function fieldErrorId(element) {
  return `${element.id || element.name}-autosave-error`
}
