import { Controller } from "@hotwired/stimulus"
import * as WebAuthnJSON from "@github/webauthn-json"

export default class extends Controller {
  static targets = ["password", "factor", "code", "codeFields", "smsFields", "credential", "feedback", "submit"]
  static values = { optionsUrl: String, smsUrl: String, error: String, preparing: String, sending: String }

  connect() {
    this.changeMethod()
  }

  changeMethod() {
    if (!this.hasFactorTarget) return

    const method = this.factorTarget.value
    this.codeFieldsTarget.hidden = method === "webauthn"
    this.smsFieldsTarget.hidden = method !== "sms"
    this.codeTarget.required = method !== "webauthn"
    this.clearProof()
  }

  clearProof() {
    this.codeTarget.value = ""
    this.credentialTarget.value = ""
    this.feedbackTarget.textContent = ""
  }

  async submit(event) {
    if (!this.hasFactorTarget || this.factorTarget.value !== "webauthn" || this.credentialTarget.value) return

    event.preventDefault()
    this.submitTarget.disabled = true
    this.feedbackTarget.textContent = this.preparingValue
    try {
      const options = await this.request(this.optionsUrlValue)
      const credential = await WebAuthnJSON.get({ publicKey: options })
      this.credentialTarget.value = JSON.stringify(credential)
      this.element.requestSubmit()
    } catch {
      this.feedbackTarget.textContent = this.errorValue
      this.feedbackTarget.focus()
    } finally {
      this.submitTarget.disabled = false
    }
  }

  async sendSms(event) {
    if (!this.passwordTarget.reportValidity()) return

    const button = event.currentTarget
    button.disabled = true
    this.feedbackTarget.textContent = this.sendingValue
    try {
      const result = await this.request(this.smsUrlValue)
      this.feedbackTarget.textContent = result.message
      this.codeTarget.focus()
    } catch {
      this.feedbackTarget.textContent = this.errorValue
    } finally {
      button.disabled = false
    }
  }

  async request(url) {
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 15000)
    try {
      const response = await fetch(url, {
        method: "POST", credentials: "same-origin", body: new FormData(this.element), signal: controller.signal,
        headers: { Accept: "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content }
      })
      if (!response.ok) throw new Error("reauthentication_refused")

      return await response.json()
    } finally {
      clearTimeout(timeout)
    }
  }
}
