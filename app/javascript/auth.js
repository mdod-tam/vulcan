import * as WebAuthnJSON from "@github/webauthn-json";

// Cached constants
const CSRF_TOKEN = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || null;
const FETCH_TIMEOUT = 15000; // ms

// Toggle verbose logging
const DEBUG = false;

// Endpoint mappings
const ENDPOINTS = {
  verify: type => `/two_factor_authentication/verify/${type}`,
  options: type => `/two_factor_authentication/verification_options/${type}`,
  create: type => `/two_factor_authentication/credentials/${type}`,
  success: type => `/two_factor_authentication/credentials/${type}/success`,
  destroy: (type, id) => `/two_factor_authentication/credentials/${type}/${id}`,
  smsVerify: () => "/two_factor_authentication/credentials/sms/verify",
  smsConfirm: () => "/two_factor_authentication/credentials/sms/confirm",
  smsResend: () => "/two_factor_authentication/credentials/sms/resend"
};

// Simple centralized logger
const Logger = {
  log: (...args) => { if (DEBUG) console.log(...args); },
  warn: (...args) => { if (DEBUG) console.warn(...args); },
  error: (...args) => console.error(...args) // could hook into external service here
};

const Auth = {
  debug: DEBUG,

  // Retrieve CSRF token (cached)
  getCSRFToken() {
    return CSRF_TOKEN;
  },

  // Build endpoint URL
  getEndpointUrl(operation, type, id = null) {
    const fn = ENDPOINTS[operation];
    return fn ? fn(type, id) : '/two_factor_authentication';
  },

  // Core fetch with timeout and retries on 502/503
  async sendRequest(url, method, body = null) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT);

    const options = {
      method,
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": this.getCSRFToken()
      },
      credentials: 'same-origin',
      signal: controller.signal
    };
    if (body) {
      options.headers["Content-Type"] = "application/json";
      options.body = JSON.stringify(body);
    }

    const maxRetries = 3;
    let attempt = 0;
    let backoff = 500;

    while (attempt <= maxRetries) {
      try {
        const response = await fetch(url, options);
        if ([502, 503].includes(response.status) && attempt < maxRetries) {
          Logger.warn(`Transient ${response.status}, retry #${attempt + 1} in ${backoff}ms`);
          attempt++;
          await new Promise(res => setTimeout(res, backoff));
          backoff *= 2;
          continue;
        }
        clearTimeout(timeoutId);
        return this.handleResponse(response);
      } catch (error) {
        if (error.name === 'AbortError') {
          clearTimeout(timeoutId);
          return this.formatError("Request timed out. Please try again.");
        }
        clearTimeout(timeoutId);
        Logger.error(`Network error during ${method} to ${url}:`, error);
        return this.formatError("Network error. Please check your connection and try again.");
      }
    }

    clearTimeout(timeoutId);
    return this.formatError("Operation failed after multiple attempts.");
  },

  // Handle fetch response
  async handleResponse(response) {
    if (response.ok) {
      const data = await response.json();
      Logger.log("Operation successful:", data);
      if (data.redirect_url) window.location.replace(data.redirect_url);
      return { success: true, data };
    } else {
      try {
        const errorData = await response.json();
        Logger.error(`Operation failed with status ${response.status}:`, errorData);
        return {
          success: false,
          message: errorData.error || 'Operation failed',
          details: errorData.details || ''
        };
      } catch (_) {
        const errorText = await response.text();
        Logger.error(`Operation failed with status ${response.status}:`, errorText);
        return {
          success: false,
          message: `Operation failed: ${errorText || 'Unknown error'}`,
          details: ''
        };
      }
    }
  },

  // Consistent error object
  formatError(message, details = "") {
    return { success: false, message, details };
  },

  // Feedback handler: accepts DOM element or callback
  updateFeedback(target, message, isError = true) {
    if (typeof target === 'function') {
      target(message, isError);
      return;
    }
    if (!target) return;
    target.textContent = message;
    target.classList.remove('hidden');
    isError ? target.classList.add('error') : target.classList.remove('error');
  },

  // Map WebAuthn errors to user messages
  getErrorMessage(error) {
    const map = {
      NotAllowedError: "The operation was cancelled or timed out.",
      NotSupportedError: "Your browser doesn't support this feature or device.",
      SecurityError: "The operation was blocked for security reasons.",
      AbortError: "The operation was aborted.",
      InvalidStateError: "The device is not in a valid state for this operation."
    };
    return map[error.name] || "Failed to complete operation.";
  },

  // Generic code verifier for TOTP/SMS
  async verifyCode(method, code, callbackUrl, feedback) {
    this.updateFeedback(feedback, `Verifying ${method.toUpperCase()} code...`, false);
    Logger.log(`Verifying ${method.toUpperCase()} code`);
    const result = await this.sendRequest(callbackUrl, 'POST', { code, method });
    if (!result.success) this.updateFeedback(feedback, result.message);
    return result;
  },

  // WebAuthn registration
  async registerWebAuthnCredential(callbackUrl, credentialOptions, nickname, feedback) {
    this.updateFeedback(feedback, "Preparing to register security key...", false);
    try {
      Logger.log("Requesting credential creation with options:", credentialOptions);
      const credential = await WebAuthnJSON.create({ publicKey: credentialOptions });
      Logger.log("Credential creation successful:", credential);

      const urlObj = new URL(callbackUrl, window.location.origin);
      const postUrl = urlObj.pathname;
      if (nickname) credential.credential_nickname = nickname;
      else Logger.warn("No nickname provided");

      const postData = { ...credential, credential_nickname: nickname };
      const result = await this.sendRequest(postUrl, 'POST', postData);
      if (!result.success) this.updateFeedback(feedback, result.message);
      return result;
    } catch (error) {
      Logger.error("Registration failed:", error);
      const msg = this.getErrorMessage(error);
      this.updateFeedback(feedback, msg);
      return this.formatError(msg, error.message);
    }
  },

  // WebAuthn verification
  async verifyWebAuthnCredential(credentialOptions, callbackUrl, feedback) {
    this.updateFeedback(feedback, "Preparing to verify security key...", false);
    try {
      Logger.log("Requesting credential assertion with options:", credentialOptions);
      const credential = await WebAuthnJSON.get({ publicKey: credentialOptions });
      Logger.log("Assertion successful:", credential);

      const wrapped = { two_factor_authentication: credential };
      const url = callbackUrl || this.getEndpointUrl('verify', 'webauthn');
      const result = await this.sendRequest(url, 'POST', wrapped);
      if (!result.success) this.updateFeedback(feedback, result.message);
      return result;
    } catch (error) {
      Logger.error("Verification failed:", error);
      const msg = this.getErrorMessage(error);
      this.updateFeedback(feedback, msg);
      return this.formatError(msg, error.message);
    }
  },

  // Request SMS code
  async requestSmsCode(url, feedback) {
    this.updateFeedback(feedback, "Sending verification code...", false);
    Logger.log("Requesting SMS code");
    const result = await this.sendRequest(url, 'POST');
    if (result.success) this.updateFeedback(feedback, "Verification code sent. Please check your phone.", false);
    else this.updateFeedback(feedback, result.message);
    return result;
  }
};

// Named exports for clarity
const registerWebAuthn = (callbackUrl, credentialOptions, nickname, feedback) =>
  Auth.registerWebAuthnCredential(callbackUrl, credentialOptions, nickname, feedback);

const verifyWebAuthn = (credentialOptions, callbackUrl, feedback) =>
  Auth.verifyWebAuthnCredential(credentialOptions, callbackUrl, feedback);

const verifyTotpCode = (code, callbackUrl, feedback) =>
  Auth.verifyCode('totp', code, callbackUrl, feedback);

const verifySmsCode = (code, callbackUrl, feedback) =>
  Auth.verifyCode('sms', code, callbackUrl, feedback);

const requestSmsCode = (url, feedback) =>
  Auth.requestSmsCode(url, feedback);

export {
  Auth as default,
  registerWebAuthn,
  verifyWebAuthn,
  verifyTotpCode,
  verifySmsCode,
  requestSmsCode
};
