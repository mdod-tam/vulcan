# Authentication And MFA

This guide describes the current sign-in and multi-factor authentication behavior in MAT Vulcan. It is not a general WebAuthn/TOTP/SMS tutorial; it is a map of the repo's current ownership boundaries.

---

## 1. Sign-In Flow

Password sign-in starts in `SessionsController#create`.

The controller:

- looks up users through `User.find_by_email`, which normalizes email and works with encrypted email storage
- checks account lock state before password authentication
- records failed password attempts
- signs the user in immediately when no second factor is enabled
- starts the MFA flow when the user has any second factor

User password/session behavior lives in `UserAuthentication`.

Current account-lock behavior:

- maximum failed login attempts: 5
- lock duration: 1 hour
- password reset tokens expire after 20 minutes
- email verification tokens expire after 1 day

Session records are stored through the `Session` model, and the signed session cookie contains the session token.

---

## 2. MFA Enrollment Policy

`ApplicationController#enforce_required_mfa_enrollment` requires MFA enrollment for these roles:

- administrators
- evaluators
- trainers
- vendors

Constituents may use MFA, but the current enforcement hook does not require it for them.

When a required user is authenticated but has no second factor, the app redirects them to `setup_two_factor_authentication_path`.

`User#second_factor_enabled?` is true when the user has at least one of:

- WebAuthn credential
- TOTP credential
- verified SMS credential

---

## 3. MFA Owners

| Area | Current owner |
| --- | --- |
| Password sign-in and MFA handoff | `SessionsController` |
| MFA verification flow | `TwoFactorAuthenticationsController` |
| MFA credential setup/removal | `TwoFactorCredentialsController` |
| Shared verification helpers | `TwoFactorVerification` |
| Session key/challenge helpers | `TwoFactorAuth` in `config/initializers/two_factor_auth.rb` |
| WebAuthn credentials | `WebauthnCredential` |
| Authenticator app credentials | `TotpCredential` |
| SMS credentials | `SmsCredential` |
| SMS login challenge state | `TwoFactor::SmsLoginChallenge` |
| Twilio Verify API wrapper | `TwilioVerifyService` |

Keep new MFA behavior inside these owners so setup, verification, logging, and session cleanup stay consistent.

---

## 4. Shared MFA Session State

`TwoFactorAuth` defines the session keys used across MFA flows.

Current temporary state includes:

- the user ID currently completing MFA
- the selected or active MFA type
- the current challenge
- metadata for the challenge
- return path after successful authentication
- verified timestamp after MFA completion

`TwoFactorAuth.abort_authentication` clears temporary MFA state. Sign-out calls it before removing the normal session cookie.

The challenge is not always cleared at the exact same moment as successful verification because JSON/WebAuthn completion needs to create the final application session first. Do not add manual session cleanup in a controller without checking the existing flow.

---

## 5. WebAuthn

WebAuthn is configured in `config/initializers/webauthn.rb`.

Current configuration behavior:

- relying party name is `MAT Vulcan`
- production requires `APPLICATION_HOST`
- production origin is derived as `https://APPLICATION_HOST`
- development allows `http://localhost:3000`
- development relying party ID is `localhost`
- production relying party ID comes from `WEBAUTHN_RP_ID` when present, otherwise the application host
- credential option timeout is 120 seconds

Credential setup is handled by `TwoFactorCredentialsController`. The controller generates a WebAuthn user handle if missing, stores the challenge in session, verifies the browser response, and saves `external_id`, encrypted `public_key`, nickname, sign count, and authenticator type metadata.

Verification is handled by `TwoFactorAuthenticationsController` through `TwoFactorVerification`. It checks the stored challenge, verifies the credential, updates sign count, and marks the MFA step complete.

---

## 6. TOTP

TOTP setup is handled by `TwoFactorCredentialsController`.

Current behavior:

- the setup flow stores a generated secret in MFA challenge metadata
- secrets are validated as Base32 before use
- QR-code generation uses the validated secret only
- the saved `TotpCredential#secret` is encrypted
- login verification accepts a 30-second drift behind and ahead
- successful verification updates `last_used_at`

Do not pass raw secret params directly into QR generation or credential creation. The existing helper validates secrets to avoid XSS-prone setup flows.

---

## 7. SMS

SMS setup and login use Twilio Verify through `TwilioVerifyService`.

Important pieces:

- `SmsCredential` stores a normalized phone number and `verified_at`
- only verified SMS credentials count as enabled
- setup stores pending phone/challenge state before creating a confirmed credential
- login SMS challenges live in `TwoFactor::SmsLoginChallenge`
- challenge TTL is 10 minutes
- resend cooldown is 30 seconds
- a short cache lock prevents duplicate SMS sends for the same credential
- test mode accepts `123456`; development without Twilio config simulates sends

The app does not store plain SMS codes. It stores Twilio Verify metadata such as verification SID and checks the submitted code through Twilio Verify.

---

## 8. Logging And Audit Notes

MFA success and failure are logged through Rails logs via `TwoFactorAuth.log_verification_success` and `log_verification_failure`.

Password failures update counters on the user. Account recovery and password reset flows create their own events where needed.

Do not assume every MFA attempt creates an `Event` row. The current MFA flow primarily uses application logs for MFA verification attempts.

---

## 9. Testing Guidance

Use the tests that match the layer you are changing:

- `test/controllers/sessions_controller_test.rb` for password-to-MFA handoff
- `test/controllers/mfa_enrollment_policy_test.rb` for role-based enrollment enforcement
- `test/controllers/two_factor_authentication_webauthn_test.rb` for WebAuthn verification routing
- `test/controllers/two_factor_authentication_sms_selection_test.rb` for SMS method selection/resend behavior
- `test/services/twilio_verify_service_test.rb` for Twilio Verify wrapper behavior
- `test/services/two_factor/challenge_hydration_test.rb` for SMS challenge hydration
- `test/system/webauthn_sign_in_test.rb` and `test/system/two_factor_authentication_flow_test.rb` for end-to-end browser coverage

Test mode has deliberate shortcuts, especially SMS code acceptance. Keep production behavior in mind when writing assertions.

---

## 10. Troubleshooting

### User keeps landing on MFA setup

Check the user role and `User#second_factor_enabled?`. Required roles must have WebAuthn, TOTP, or a verified SMS credential.

### WebAuthn fails in production

Check `APPLICATION_HOST`, `WEBAUTHN_RP_ID`, HTTPS origin, and whether the browser origin matches the configured allowed origins.

### SMS code cannot be sent

Check Twilio account SID, auth token, Verify service SID, phone formatting, and whether a duplicate send is already in progress.

### TOTP code fails

Check that the credential exists, the secret decrypts, and client/server clocks are reasonably close.

---

## 11. Change Rules

When changing authentication:

- Keep password sign-in and MFA handoff in `SessionsController`.
- Keep MFA setup/removal in `TwoFactorCredentialsController`.
- Keep MFA verification in `TwoFactorAuthenticationsController` and `TwoFactorVerification`.
- Use `TwoFactorAuth` session keys instead of inventing new session state.
- Do not count unverified SMS credentials as enabled.
- Do not store SMS codes in our database.
- Do not bypass `User.find_by_email` for login lookup.
- Do not add role-based MFA exceptions without updating tests.
- Be careful with direct column writes in auth bookkeeping; the existing uses are narrow and documented in code.
