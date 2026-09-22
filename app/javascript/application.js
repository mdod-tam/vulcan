// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import * as ActiveStorage from "@rails/activestorage"
import * as WebAuthnJSON from "@github/webauthn-json"
import Auth from "./auth"
// Toast notifications removed in favor of native Rails flash messages

import "./controllers"

// Make WebAuthnJSON and Auth available globally if needed for debugging, or remove if not
window.WebAuthnJSON = WebAuthnJSON
window.Auth = Auth


ActiveStorage.start()
