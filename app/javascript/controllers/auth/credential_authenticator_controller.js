import { Controller } from "@hotwired/stimulus"
import { applyTargetSafety } from "../../mixins/target_safety"
import { verifyWebAuthn } from "../../auth"

class CredentialAuthenticatorController extends Controller {
  static targets = [
    "webauthnForm",
    "verificationButton"
  ]



  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("CredentialAuthenticatorController connected")
    }
  }

  disconnect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("CredentialAuthenticatorController disconnected")
    }
  }

  // Fired when "Verify with Security Key" is clicked
  async startVerification(event) {
    event.preventDefault()

    if (!this.hasRequiredTargets('webauthnForm')) {
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
      if (process.env.NODE_ENV !== 'production') {
        console.log("No challenge in form, fetching dynamically...")
      }
      
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
        
        if (process.env.NODE_ENV !== 'production') {
          console.log("Fetched WebAuthn options:", options)
        }
      } catch (error) {
        console.error("Failed to fetch WebAuthn options:", error)
        if (error.message.includes('404')) {
          console.error("No security keys are registered for this account.")
        } else {
          console.error("Failed to get verification options. Please try again.")
        }
        return
      }
    }

    if (!challenge) {
      console.error("No challenge found after fetching")
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

      if (result.success) {
        if (process.env.NODE_ENV !== 'production') {
          console.log("WebAuthn verification successful")
        }
        console.log("Security key verified successfully!")
      } else {
        console.error(result.message || "Security key verification failed")
        if (process.env.NODE_ENV !== 'production') {
          console.error("WebAuthn verification failed:", result.details)
        }
      }
    } catch (error) {
      console.error("WebAuthn verification error:", error)
      console.error(`Error: ${error.message || "Something went wrong."}`)
    }
  }

  // Alternate entry point if you want to verify a key outside of the form flow
  async verifyKey(options) {
    try {
      const result = await verifyWebAuthn(options, null, null)

      if (result.success) {
        this.withTarget('verificationButton', (button) => {
          button.textContent = "Verified"
          button.disabled = true
        })
        console.log("Security key verified successfully!")
      } else {
        console.error(result.message || "Security key verification failed")
        if (process.env.NODE_ENV !== 'production') {
          console.error("Key verification error:", result.details)
        }
      }

      return result
    } catch (error) {
      console.error("Key verification error:", error)
      console.error(`Error: ${error.message || "Something went wrong."}`)
      return { success: false, message: error.message }
    }
  }
}

// Apply target safety mixin
applyTargetSafety(CredentialAuthenticatorController)

export default CredentialAuthenticatorController
