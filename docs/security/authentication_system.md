# Authentication and MFA

Password sign-in, then a second factor that some roles must have and others may.

A database-backed session identifies every request after that.

Password reset and lost-security-key recovery are separate flows with their own rules.

## Who can sign in

[`User.find_by_login_identifier`](../../app/models/user.rb) accepts an email or a real phone, but resolves only to an **email-backed account**. Phone-only paper records, address-only records, and synthetic dependent contacts are not login identities, and a guardian's shared contact does not give a dependent one. The account must also pass `public_login_active?`, which excludes merged, inactive, and suspended records; legacy rows with no status remain eligible. Account creation and the contact rules behind this live in [user management](../development/user_management_features.md).

## Sign-in

[`HomeController#index`](../../app/controllers/home_controller.rb) redirects `/` to sign-in for visitors or the signed-in user's dashboard. Administrators, constituents, vendors, evaluators, and trainers each have a dashboard; other user types fall back to profile editing through `ApplicationController#_dashboard_for`. There is no separate introductory homepage.

Required password changes and MFA enrollment take priority. Pending MFA verification is not a completed sign-in. Registration, password/account recovery, help pages, and token-based document tasks keep their own public entry points.

[`SessionsController#create`](../../app/controllers/sessions_controller.rb) resolves the identifier and rejects locked accounts before checking the password or updating either failure counter. An unknown account or wrong password goes through the shared IP rate limiter first; only requests it allows increment a matched account's failure count. Valid credentials bypass that limiter and either create a session or start MFA verification.

Session creation itself is [`ApplicationController#_create_and_set_session_cookie`](../../app/controllers/application_controller.rb), which locks the user and rechecks them before writing a [`Session`](../../app/models/session.rb); password-only sign-in also re-verifies the submitted identifier and password inside that lock, so a merge or credential change landing mid-request cannot be accepted on stale reads. Registration creates its first session by a separate path.

The signed `session_token` cookie identifies the row; [`Authentication`](../../app/controllers/concerns/authentication.rb) resolves it thereafter, and sign-out deletes session, cookie, and any pending MFA state.

Five recorded password failures lock the account for an hour ([`UserAuthentication`](../../app/models/concerns/user_authentication.rb)) — separate from request throttling.

## Second factors

Administrators, evaluators, trainers, and vendors must enroll; constituents may. [`ApplicationController#enforce_required_mfa_enrollment`](../../app/controllers/application_controller.rb) redirects a required role with no enabled factor into setup. `second_factor_enabled?` counts a WebAuthn credential, a TOTP credential, or a **verified** SMS credential — an unverified SMS credential is why an account can loop back to setup.

| Factor | Stored and verified |
| --- | --- |
| WebAuthn | [`WebauthnCredential`](../../app/models/webauthn_credential.rb): credential ID, encrypted public key, sign count. Verification checks the session challenge and updates the count. |
| TOTP | [`TotpCredential`](../../app/models/totp_credential.rb): encrypted secret, Base32-validated before QR generation or save. Verification allows 30 seconds of drift either way. |
| SMS | [`SmsCredential`](../../app/models/sms_credential.rb): phone and verification state. Twilio Verify checks the code; only challenge metadata is stored here. Login challenges last 10 minutes, with a 30-second resend cooldown and a short duplicate-send lock. |

Registration and verification are split across [`TwoFactorCredentialsController`](../../app/controllers/two_factor_credentials_controller.rb), [`TwoFactorAuthenticationsController`](../../app/controllers/two_factor_authentications_controller.rb), the shared [`TwoFactorVerification`](../../app/controllers/concerns/two_factor_verification.rb) concern, and [`TwoFactorAuth`](../../config/initializers/two_factor_auth.rb), which holds the temporary user, challenge, return path, and completion state. SMS send/resend lifetimes are in [`TwoFactor::SmsLoginChallenge`](../../app/services/two_factor/sms_login_challenge.rb) and [`TwilioVerifyService`](../../app/services/twilio_verify_service.rb).

Two ordering details matter: JSON and WebAuthn completion must create the session before clearing the challenge, and resolving the temporary MFA user rechecks `public_login_active?`, so an account retired mid-sign-in cannot finish verifying.

The public sign-in locale is carried into MFA redirects and verification URLs; it does not come from the matched account. The security-key page and method chooser support English and Spanish. Credential lookup, challenge, and signature failures return the same JSON 422 response and `verification_failed` code with translated retry guidance. Server logs retain the failure category, without sending verifier details to the browser.

WebAuthn enrollment uses **Maryland Accessible Telecommunications** as its display name. The [WebAuthn initializer](../../config/initializers/webauthn.rb) configures the RP ID and allowed origins separately; these define the credential scope and accepted origins.

TOTP provisioning URIs retain `MatVulcan` as the issuer, a deliberate exception to the public program name. The issuer labels new enrollments; changing it does not rename existing authenticator entries or alter TOTP codes.

## Password reset and account access

[`PasswordsController#create`](../../app/controllers/passwords_controller.rb) resolves account and delivery route together through `User.find_for_account_access`: an email selects email delivery; a phone selects SMS only when that same email-backed account has an SMS-capable number. Matched, unmatched, undeliverable, and throttled requests all produce the same public confirmation.

Links are built against the [configured public host](../../app/services/canonical_public_url_options.rb) rather than the request host, and production refuses the `example.com` placeholder.

The `:password_reset` token expires in **20 minutes** and is derived from the password digest, normalized login email, and normalized phone — so changing any of those invalidates outstanding links, including one already texted to a number a merge later removed. Reformatting a phone or email cosmetically does not, since normalization absorbs it. Redemption re-resolves the token under lock before writing the password. Signed-in and forced changes go through [`Users::PasswordUpdateService`](../../app/services/users/password_update_service.rb).

Issuing a reset link deliberately sits outside the merge lock, so a racing contact change can send a now-dead link to an old destination. Token invalidation and locked redemption are what make that safe; see the [merge integrity boundary](../development/service_architecture.md#merge-integrity-lock-boundary).

## Lost security keys

[`AccountRecoveryController`](../../app/controllers/account_recovery_controller.rb) accepts the same eligible identifiers and files a request for staff. A partial unique index allows one pending [`RecoveryRequest`](../../app/models/recovery_request.rb) per user; repeat submissions return the same public confirmation and reuse the pending request.

[`Admin::RecoveryRequestsController`](../../app/controllers/admin/recovery_requests_controller.rb) approves it and removes **WebAuthn credentials only** — TOTP and SMS survive. Approval rolls back if the notification record cannot be created or reports an immediate delivery error, though a successfully enqueued email still proves nothing about later delivery. The admin **Delete MFA tokens** action is the broader one: all factor types plus sessions ([admin tools](../development/user_management_features.md#admin-tools)).

## Public copy constraints

[Registration](../../app/controllers/registrations_controller.rb) routes an exact email-backed match to sign-in and gives every other hard contact collision the same support-only message. That message must not reveal whether the matched record is email-backed, phone-only, admin-created, SMS-capable, or reachable at all, must not echo the submitted email, and must not offer a sign-in or account-access call to action — those would each answer, by implication, a question about someone else's record. The form may keep the person's own entered values for correction. Account-access requests hold the same line, with one confirmation for matched, unmatched, undeliverable, and throttled alike.

The constraint lives in translated copy as much as in the controllers. [Registration response tests](../../test/controllers/registrations_controller_test.rb) and [account-access tests](../../test/controllers/passwords_controller_test.rb) cover it.

## Unauthenticated requests

[`Authentication#authenticate_user!`](../../app/controllers/concerns/authentication.rb) answers by format: JSON gets a 401 with `Cache-Control: no-store` and `{ "error": "authentication_required", "sign_in_path": "/sign_in" }`; HTML and Turbo get a redirect to sign-in, with the attempted GET or HEAD path stored for the return trip. A JSON caller that silently retries will just fail again — and if the page holds selected files, reloading it loses them, so the sign-in prompt belongs in the existing page.

[`AuthRateLimit`](../../app/services/auth_rate_limit.rb) owns failed sign-in, account-access, and recovery throttles, with policy-backed limits and identifier digests in both keys and audit metadata. [`PublicAuditActor`](../../app/services/public_audit_actor.rb) attributes unauthenticated events to the configured system user, or skips the event with a warning when that user is missing.

Provision `system@mdmat.org` during [initial account setup](../infrastructure/setup_and_maintenance.md#initial-accounts). Public requests do not create it. A registration that needs a duplicate-review case also depends on this actor and rolls back if it is absent.

MFA verification mostly writes Rails logs through `TwoFactorAuth` rather than `Event` rows, so attempt history is not in the audit trail.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Loops back to MFA setup | Role requires a factor and `second_factor_enabled?` is false — commonly an unverified SMS credential. |
| WebAuthn fails on a deployed host | [WebAuthn config](../../config/initializers/webauthn.rb): production needs `APPLICATION_HOST` and uses its HTTPS origin; `WEBAUTHN_RP_ID` overrides; development is `localhost`. |
| SMS not sent | [Twilio config](../../config/initializers/twilio.rb): `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_VERIFY_SERVICE_SID`, phone format, resend cooldown. |
| TOTP code rejected | Missing credential, secret decryption, or clock drift beyond 30 seconds. |
| Reset link stopped working | Expiry, a changed password/email/phone, or an account no longer login-active. |

Tests simulate Twilio Verify and accept `123456`, and development falls back to the same simulation when Verify is unconfigured — neither says anything about production SMS working.

## Tests

- [Root redirects](../../test/controllers/home_controller_test.rb) — role destinations, expired sessions, password/MFA gates, and public sign-in links.
- [Sessions](../../test/controllers/sessions_controller_test.rb), [enrollment policy](../../test/controllers/mfa_enrollment_policy_test.rb)
- [WebAuthn verification](../../test/controllers/two_factor_authentication_webauthn_test.rb), [SMS selection](../../test/controllers/two_factor_authentication_sms_selection_test.rb)
- [Password reset](../../test/controllers/passwords_controller_test.rb), [concurrent resets](../../test/controllers/passwords_controller_concurrency_test.rb)
- [Recovery requests](../../test/controllers/account_recovery_controller_test.rb), [admin approval](../../test/controllers/admin/recovery_requests_controller_test.rb)
- [Twilio Verify](../../test/services/twilio_verify_service_test.rb)

The authentication test helpers bypass parts of sign-in and MFA, so tests of those boundaries have to drive the real flow ([testing and debugging](../development/testing_and_debugging_guide.md)).
