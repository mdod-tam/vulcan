import { Controller } from "@hotwired/stimulus"
import { verifyWebAuthn } from "../../auth"

class CredentialAuthenticatorController extends Controller {
  static targets = [
    "webauthnForm",
    "verificationButton",
    "feedback"
  ]
  static values = { messages: Object, verificationUrl: String }

  async startVerification(event) {
    event.preventDefault()
    if (!this.hasWebauthnFormTarget) return

    const button = this.verificationButtonTarget
    if (button.disabled) return

    let failureMessage = this.messagesValue.optionsError
    try {
      button.disabled = true
      button.setAttribute("aria-disabled", "true")
      this.feedbackTarget.textContent = this.messagesValue.preparing
      this.feedbackTarget.classList.remove("error")

      const form = this.webauthnFormTarget
      const formData = new FormData(form)
      let challenge = formData.get('challenge')
      let timeout = parseInt(formData.get('timeout')) || 30000
      let rpId = formData.get('rp_id')
      let allowCredentials

      try {
        allowCredentials = JSON.parse(formData.get('allow_credentials') || '[]')
      } catch {
        allowCredentials = []
      }

      if (!challenge) {
        const response = await fetch(form.action || '/two_factor_authentication/verification_options/webauthn', {
          headers: { "Accept": "application/json" },
          credentials: "same-origin"
        })
        if (!response.ok) {
          console.error(`Security-key options request failed with status ${response.status}`)
          this.feedbackTarget.textContent = this.messagesValue.optionsError
          return
        }
        const options = await response.json()

        challenge = options.challenge
        timeout = options.timeout || 30000
        rpId = options.rpId
        allowCredentials = options.allowCredentials || []
      }

      if (!challenge) {
        this.feedbackTarget.textContent = this.messagesValue.optionsError
        return
      }

      failureMessage = this.messagesValue.failed
      const result = await verifyWebAuthn(
        { challenge, timeout, rpId, allowCredentials, userVerification: "required" },
        this.verificationUrlValue,
        this.feedbackTarget,
        this.messagesValue
      )
      if (result.success) this.feedbackTarget.textContent = this.messagesValue.verified
    } catch (error) {
      console.error("Security-key verification could not be completed:", error)
      if (this.hasFeedbackTarget) this.feedbackTarget.textContent = failureMessage
    } finally {
      button.disabled = false
      button.setAttribute("aria-disabled", "false")
    }
  }

}

export default CredentialAuthenticatorController
