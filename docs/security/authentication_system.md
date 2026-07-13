# Authentication And MFA

This guide describes the current sign-in and multi-factor authentication behavior in MAT Vulcan. It is not a general WebAuthn/TOTP/SMS tutorial; it is a map of the repo's current ownership boundaries.

---

## 1. Sign-In Flow

Password sign-in starts in `SessionsController#create`.

The controller:

- looks up users through `User.find_by_login_identifier`, which accepts email or phone for **email-backed portal accounts** (`real_email?` required; phone match also requires `real_phone?` on the same user), normalizes input, rejects malformed `@` input, rejects synthetic dependent emails and placeholder phones, and works with encrypted email storage
- **does not** treat phone-only or address-only records as portal accounts — those truthful paper/admin records do not match public sign-in, account access, or WebAuthn recovery
- public self-registration requires a real email address; phone is optional, requires an explicit phone type when present, and adds an alternate login identifier only when it can be stored on the new email-backed portal account; `DuplicateDetectionService` uses context `:public_registration` so duplicate email redirects to sign-in without authenticating or exposing the submitted email, while duplicate phone/non-portal contact collisions render support-only copy and must not reveal whether the match was email-backed, phone-only, paper/admin-created, text-capable, or delivery-capable
- checks sign-in throttling through `AuthRateLimit` action `:sign_in_attempt` and scope `:ip`; denied public attempts are audited through `PublicAuditActor` with digest metadata rather than raw submitted contact or IP values
- checks account lock state before password authentication
- records failed password attempts
- signs the user in immediately when no second factor is enabled
- starts the MFA flow when the user has any second factor

User password/session behavior lives in `UserAuthentication`.

Account access (the “Forgot password?” / send reset link flow) lives in `PasswordsController#create`. It uses `User.find_for_account_access`, which delegates identity lookup to `find_by_login_identifier` and selects delivery separately: email for email-shaped contact on an email-backed account, SMS only when the same account has `sms_capable_phone?` and phone-shaped contact was entered. Email and SMS reset links are built from configured canonical URL options, not the inbound request host, and production refuses the unsafe `example.com` fallback. Every outcome returns the same public confirmation; delivery attempts, including matched accounts with no available delivery route, are recorded in audit logs only after the account-access rate-limit gate. `AuthRateLimit` owns the account-access `:ip`, `:contact_ip`, and matched `:user_ip` throttles.

WebAuthn recovery in `AccountRecoveryController` uses the same email-backed login lookup via a contact field. `AuthRateLimit` owns the account-recovery `:ip`, `:contact_ip`, and matched `:user_ip` throttles. Throttling keys and unmatched rate-limit audit metadata use digests of submitted contacts rather than raw identifiers, and denied public recovery/account-access attempts are logged through `PublicAuditActor`.

Current account-lock behavior:

- maximum failed login attempts: 5
- lock duration: 1 hour
- password reset tokens expire after 20 minutes and are invalidated by a successful password change or login-email change because token generation is tied to both the password salt and normalized email; token consumption re-resolves the token and rechecks account activity while holding the user lock so a concurrent merge cannot use a stale resolution

Recovery requests are durable and idempotent: a partial unique index allows only one pending request per user, duplicate pending submissions coalesce into the same public confirmation, and a new pending request is allowed after the previous request is resolved. Public creation and admin approval lock and recheck the account before changing recovery state, so neither can create or approve recovery work for a record retired by a concurrent merge. The index migration assumes alpha/shared environments do not already contain duplicate pending recovery requests for the same user; resolve any such rows before migrating. Admin approval removes WebAuthn credentials only if the approval notification record can be created and queued without a synchronous delivery error.

There is no live email-verification link flow in the current code. Public signup sends `ApplicationNotificationsMailer.registration_confirmation`; any future email-verification work should add a deliberate caller, query-parameter bearer token handling, and end-to-end tests instead of relying on the historical `user_mailer_email_verification` template seeds.

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

`User#public_login_active?` rejects merged, inactive, and suspended records (legacy NULL status is treated as active). It gates every point that resolves the in-progress MFA user — `ApplicationController#find_user_for_two_factor` and `TwoFactorAuthenticationsController#find_user_for_two_factor` both return `nil` for a record that fails this check, so a record retired by an admin merge mid-login cannot reach method selection, verification options, SMS resend, or credential updates; it fails closed to sign-in instead of only being caught at final session creation. This applies to both the HTML and JSON success paths in `TwoFactorAuthenticationsController#handle_successful_verification`; either path calls `TwoFactorAuth.abort_authentication` (clearing the challenge and any verified/temp-user state) when session creation fails, so nothing can be replayed regardless of response format.

`ApplicationController#_create_and_set_session_cookie` re-checks `public_login_active?` and is the single chokepoint for both password sign-in and 2FA completion, so a record retired between password entry and MFA completion still cannot finish authenticating. Because `user` can be loaded well before this runs (`SessionsController#create` loads it before password verification), session creation locks and rechecks the user rather than trusting the in-memory instance—a concurrent admin merge that retires the record in between must not let a stale, already-loaded object mint a session. `Authentication#current_user` adds an independent check when each request first resolves the session user; a later request destroys a stale session and clears its cookie. Within an already-running request, `current_user` is intentionally memoized, so merge-sensitive persistence boundaries (profile/contact edits, application submission/autosave, password reset, recovery, and secure-form issuance) take the user-row lock and recheck retirement before writing. This is defense in depth on top of `Users::DuplicateMergeService#expire_duplicate_sessions!`, which destroys the retired duplicate's sessions as part of every merge.

Merged rows are historical identities, not alternate live contact owners. The merge clears their primary email/phone, a data migration releases contact retained by PR192-era merges, locked constituent and admin profile mutations reject a record retired mid-request, and the `UserMergeIntegrity` invariant prevents an ordinary later edit from restoring primary email or phone to a merged row.

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

- `test/controllers/sessions_controller_test.rb` for password-to-MFA handoff, including the reload-before-check race where the record is retired between the initial user lookup and session creation
- `test/controllers/mfa_enrollment_policy_test.rb` for role-based enrollment enforcement
- `test/controllers/two_factor_authentication_webauthn_test.rb` for WebAuthn verification routing
- `test/controllers/two_factor_authentication_sms_selection_test.rb` for SMS method selection/resend behavior
- `test/services/twilio_verify_service_test.rb` for Twilio Verify wrapper behavior
- `test/services/two_factor/challenge_hydration_test.rb` for SMS challenge hydration
- `test/system/webauthn_sign_in_test.rb` and `test/system/two_factor_authentication_flow_test.rb` for end-to-end browser coverage
- `test/integration/merged_user_two_factor_gate_test.rb` for the `public_login_active?` fail-closed gate across TOTP verification and the JSON success path's session-failure cleanup
- `test/integration/authentication_test.rb` for `Authentication#current_user`'s per-request recheck, including a live session whose user was retired after the session was created

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
- Use `User.find_by_login_identifier` for password sign-in lookup instead of calling `User.find_by_email` or `User.find_by_phone` directly.
- Delegate account-access identity lookup and delivery selection to `User.find_for_account_access` from `PasswordsController#create`; do not reimplement parallel lookup rules in the controller.
- Do not add role-based MFA exceptions without updating tests.
- Be careful with direct column writes in auth bookkeeping; the existing uses are narrow and documented in code.
