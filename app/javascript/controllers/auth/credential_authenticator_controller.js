import { Controller } from "@hotwired/stimulus"
import { verifyWebAuthn } from "../../auth"

class CredentialAuthenticatorController extends Controller {
  static targets = [
    "webauthnForm",
    "verificationButton"
  ]

  // Fired when "Verify with Security Key" is clicked
  async startVerification(event) {
    event.preventDefault()

    if (!this.hasWebauthnFormTarget) {
      // If the form target is missing, bail out
      return
    }

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

    // If no challenge in form, fetch it dynamically (old controller pattern)
    if (!challenge) {
      
      try {
        const optionsUrl = form.action || '/two_factor_authentication/verification_options/webauthn'
        const response = await fetch(optionsUrl, {
          headers: { "Accept": "application/json" },
          credentials: "same-origin"
        })
        
        if (!response.ok) {
          throw new Error(`HTTP error ${response.status}`)
        }

        const options = await response.json()
        
        challenge = options.challenge
        timeout = options.timeout || 30000
        rpId = options.rpId
        allowCredentials = options.allowCredentials || []
        
      } catch (error) {
        console.error("Failed to fetch WebAuthn options:", error)
        return
      }
    }

    if (!challenge) {
      console.error("Verification failed: No challenge provided.")
      return
    }

    try {
      const credentialOptions = {
        challenge,
        timeout,
        rpId,
        allowCredentials,
        userVerification: "required"
      }

      // Use verification endpoint instead of options endpoint
      const callbackUrl = '/two_factor_authentication/verify/webauthn'

      // We pass `null` for the feedback element, since we now use the flash outlet
      const result = await verifyWebAuthn(
        credentialOptions,
        callbackUrl,
        null
      )

      if (!result.success) {
        console.error(result.message || "Security key verification failed")
      }
    } catch (error) {
      console.error("WebAuthn verification error:", error)
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
