import { Controller } from "@hotwired/stimulus"
import { railsRequest } from "../../services/rails_request"
import { registerWebAuthn } from "../../auth.js"

class AddCredentialController extends Controller {
  static values = { callbackUrl: String }
  static targets = ["nicknameInput", "submitButton", "statusMessage"]

  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("AddCredentialController connected")
    }

    if (!this.hasCallbackUrlValue) {
      console.error("AddCredentialController requires a callback-url value.")
    }

    this.requestKey = `add-credential-${this.identifier}-${Date.now()}`

    // The register button's click starts registration, so the form has no submit handler.
    this.form = this.element;
  }

  disconnect() {
    railsRequest.cancel(this.requestKey)
  }

  async register(event) {
    event.preventDefault();

    if (process.env.NODE_ENV !== 'production') {
      console.log("Preparing your security key...")
    }
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true;
    }

    const nickname = this.hasNicknameInputTarget ? this.nicknameInputTarget.value : null;
    if (!nickname) {
      this.showNicknameError("Please enter a name so you can recognize this device later.")
      if (this.hasSubmitButtonTarget) {
        this.submitButtonTarget.disabled = false;
      }
      return;
    }

    try {
      if (process.env.NODE_ENV !== 'production') {
        console.log("Form action:", this.form.action)
      }

      const result = await railsRequest.perform({
        method: 'post',
        url: this.form.action,
        body: {}, // Empty JSON body (server gets type from URL)
        key: this.requestKey
      })

      if (result.success) {
        const credentialOptions = result.data;
        if (process.env.NODE_ENV !== 'production') {
          console.log("Received credential options:", credentialOptions)
        }
        if (process.env.NODE_ENV !== 'production') {
          console.log("Please follow your browser's prompts to register your security key...")
        }

        if (!this.hasCallbackUrlValue) {
          console.error("Missing callback URL value. Check the data attribute in the view.");
          console.error("Configuration error. Please try again or contact support.");
          if (this.hasSubmitButtonTarget) {
            this.submitButtonTarget.disabled = false;
          }
          return;
        }

        const callbackUrl = `${this.callbackUrlValue}?credential_nickname=${encodeURIComponent(nickname)}`;
        if (process.env.NODE_ENV !== 'production') {
          console.log("Using callback URL:", callbackUrl)
        }

        // No feedback element is passed, so a failure here is only logged to the console.
        const webauthnResult = await registerWebAuthn(callbackUrl, credentialOptions, nickname, null);

        if (!webauthnResult.success) {
          console.error("Security key registration failed:", webauthnResult.message || "Unknown error");
          console.error("Error details:", webauthnResult.details);

          if (this.hasSubmitButtonTarget) {
            this.submitButtonTarget.disabled = false;
          }
        }
        // A successful registration redirects from auth.js.
      } else {
        this.showNicknameError(result.message || "Could not prepare your device or security key. Please try again.")
        if (this.hasSubmitButtonTarget) {
          this.submitButtonTarget.disabled = false;
        }
      }

    } catch (error) {
      console.error("Error in WebAuthn flow:", error);
      console.error(`Error: ${error.message || "Something went wrong. Please try again."}`);

      if (this.hasSubmitButtonTarget) {
        this.submitButtonTarget.disabled = false;
      }
    }
  }

  clearNicknameError() {
    if (!this.hasNicknameInputTarget) return;

    this.nicknameInputTarget.classList.remove("border-danger-500");
    if (this.hasStatusMessageTarget) {
      this.statusMessageTarget.textContent = "";
      this.statusMessageTarget.classList.add("hidden");
    }
  }

  showNicknameError(message) {
    if (this.hasNicknameInputTarget) {
      this.nicknameInputTarget.focus();
      this.nicknameInputTarget.classList.add("border-danger-500");
    }

    if (this.hasStatusMessageTarget) {
      this.statusMessageTarget.textContent = message;
      this.statusMessageTarget.classList.remove("hidden");
    }
  }
}

export default AddCredentialController
