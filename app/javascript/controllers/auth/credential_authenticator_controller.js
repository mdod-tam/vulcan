import { Controller } from "@hotwired/stimulus"
import { verifyWebAuthn } from "../../auth"

class CredentialAuthenticatorController extends Controller {
  static targets = [
    "webauthnForm",
    "verificationButton",
    "feedback"
  ]
  static values = { messages: Object }

  async startVerification(event) {
    event.preventDefault()
    if (!this.hasWebauthnFormTarget) return

    const button = this.verificationButtonTarget
    if (button.disabled) return

    button.disabled = true
    button.setAttribute("aria-disabled", "true")
    this.feedbackTarget.textContent = this.messagesValue.preparing
    this.feedbackTarget.classList.remove("error")

    try {
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
        const options = await response.json()
        if (!response.ok) {
          this.feedbackTarget.textContent = options.error || this.messagesValue.optionsError
          return
        }

        challenge = options.challenge
        timeout = options.timeout || 30000
        rpId = options.rpId
        allowCredentials = options.allowCredentials || []
      }

      if (!challenge) {
        this.feedbackTarget.textContent = this.messagesValue.optionsError
        return
      }

      const result = await verifyWebAuthn(
        { challenge, timeout, rpId, allowCredentials, userVerification: "required" },
        '/two_factor_authentication/verify/webauthn',
        this.feedbackTarget,
        this.messagesValue
      )
      if (result.success) this.feedbackTarget.textContent = this.messagesValue.verified
    } catch {
      this.feedbackTarget.textContent = this.messagesValue.optionsError
    } finally {
      button.disabled = false
      button.setAttribute("aria-disabled", "false")
    }
  }

  // Alternate entry point if you want to verify a key outside of the form flow
  async verifyKey(options) {
    try {
      const result = await verifyWebAuthn(options, null, null)

      if (result.success) {
        if (this.hasVerificationButtonTarget) {
          const button = this.verificationButtonTarget
          button.textContent = "Verified"
          button.disabled = true
        }
      } else {
        console.error(result.message || "Security key verification failed")
      }

      return result
    } catch (error) {
      console.error("Key verification error:", error)
      return { success: false, message: error.message }
    }
  }
}

// Apply target safety mixin

export default CredentialAuthenticatorController
