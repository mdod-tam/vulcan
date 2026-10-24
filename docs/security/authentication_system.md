# Authentication and MFA

MFA (multi-factor authentication) means signing in with a password plus a second proof, such as a security key or a code.

Password sign-in comes first. Some roles must then add a second factor, and others may.

A database-backed session identifies every request after that.

Password reset and lost-security-key recovery are separate flows with their own rules.

## Who can sign in

[`User.find_by_login_identifier`](../../app/models/user.rb) accepts an email or a real phone, but it resolves only to an **email-backed account**. Phone-only paper records, address-only records, and synthetic dependent contacts are not login identities. A guardian's shared contact does not give a dependent one. The account must also pass `public_login_active?`, which excludes merged, inactive, and suspended records. Legacy rows with no status remain eligible. Account creation and the contact rules behind this live in [user management](../development/user_management_features.md).

## Sign-in

[`HomeController#index`](../../app/controllers/home_controller.rb) redirects `/` to sign-in for visitors or the signed-in user's dashboard. Administrators, constituents, vendors, evaluators, and trainers each have a dashboard. Other user types fall back to profile editing through `ApplicationController#_dashboard_for`. There is no separate introductory homepage.

Required password changes and MFA enrollment take priority. Pending MFA verification is not a completed sign-in. Registration, password and account recovery, help pages, and token-based document tasks keep their own public entry points.

[`SessionsController#create`](../../app/controllers/sessions_controller.rb) resolves the identifier and rejects locked accounts before checking the password or updating either failure counter. An unknown account or wrong password goes through the shared IP rate limiter first. A rate limiter slows or blocks repeated attempts. Only requests the limiter allows increment a matched account's failure count. Valid credentials bypass that limiter. They then either create a session or start MFA verification.

Session creation itself is [`ApplicationController#_create_and_set_session_cookie`](../../app/controllers/application_controller.rb). It locks the user and rechecks them before writing a [`Session`](../../app/models/session.rb). Password-only sign-in also re-verifies the submitted identifier and password inside that lock. A merge or credential change landing mid-request therefore cannot be accepted on stale reads. Registration uses this same session owner. After the session transaction commits, it resets the Rails browser session, preserves the intended return path, and sets the signed login cookie. Password and MFA sign-in use that same completion boundary.

The signed `session_token` cookie identifies the session row. [`Authentication`](../../app/controllers/concerns/authentication.rb) resolves it on every later request. Sign-out deletes the session, the cookie, and any pending MFA state.

## Session lifetime

Sessions have a **30-minute idle limit** and retain the existing **24-hour absolute limit**. Activity can move the idle deadline but cannot extend the absolute deadline. Background document-scan status checks do not refresh the idle deadline. The login cookie has HttpOnly, production Secure, and explicit SameSite=Lax flags.

Password sign-in, MFA completion, and registration deliberately use a browser-session cookie without `Expires` or `Max-Age`. Registration follows the same cookie lifetime policy as subsequent sign-ins; it does not request a permanent cookie. The stored session still expires at the server deadlines if a browser restores the cookie. During deployment, inspect the HTTPS sign-in and registration responses to confirm `Secure`, `HttpOnly`, and `SameSite=Lax` on `session_token`.

Authenticated requests refresh `Session#last_active_at` only when its stored value is at least one minute old. This bounds database writes and makes the idle deadline conservative by up to one minute compared with the latest request. Expiry is checked again under the session row lock before an activity write; waiting for another request cannot revive an expired session. Activity refresh runs inside `authenticate_user!`, so inherited callback ordering cannot skip the expiry recheck. Public actions that skip authentication do not refresh activity.

Admin pages also record genuine typing and interaction through an authenticated, CSRF-protected session-activity POST, at most once a minute. Background scan polling, warning timers, and session-status GETs do not renew the session. The browser checks the server's deadlines when the page opens or regains focus and before showing a five-minute warning. **Keep working** renews idle time while the session remains valid; the absolute limit still requires another sign-in. If the session expires, the page keeps its visible form input and blocks submission so staff can copy unfinished work. This does not save a draft or guarantee that signing in restores the form.

Apply [the session migration](../../db/migrate/20261022173000_add_last_active_at_to_sessions.rb) with the rest of the schema before first launch. It clears stored sessions, requiring anyone signed in on an existing instance to sign in once more. New sessions record activity at creation. An expired protected request clears browser authentication and pending session state. JSON receives the no-store 401 response described below; HTML and Turbo return to sign-in with an English or Spanish expiry alert. The redirect uses a supported request locale, then the expired session user's effective locale, then the default. An anonymous request instead receives a generic sign-in alert in its supported request locale.

Five recorded password failures lock the account for an hour ([`UserAuthentication`](../../app/models/concerns/user_authentication.rb)). This lockout is separate from request throttling.

## Second factors

Administrators, evaluators, trainers, and vendors must enroll; constituents may. [`ApplicationController#enforce_required_mfa_enrollment`](../../app/controllers/application_controller.rb) redirects a required role with no enabled factor into setup. `second_factor_enabled?` counts a WebAuthn credential, a TOTP credential, or a **verified** SMS credential. An unverified SMS credential is why an account can loop back to setup.

| Factor | Stored and verified |
| --- | --- |
| WebAuthn | WebAuthn is the browser standard behind security keys and passkeys. [`WebauthnCredential`](../../app/models/webauthn_credential.rb): credential ID, encrypted public key, sign count. Verification checks the session challenge and updates the count. |
| TOTP | TOTP is the time-based code from an authenticator app. [`TotpCredential`](../../app/models/totp_credential.rb): encrypted secret, validated as Base32 text before QR generation or save. Verification allows 30 seconds of clock drift either way. |
| SMS | [`SmsCredential`](../../app/models/sms_credential.rb): phone and verification state. Twilio Verify checks the code; only challenge metadata is stored here. Login challenges last 10 minutes, with a 30-second resend cooldown and a short duplicate-send lock. |

Registration and verification are split across [`TwoFactorCredentialsController`](../../app/controllers/two_factor_credentials_controller.rb), [`TwoFactorAuthenticationsController`](../../app/controllers/two_factor_authentications_controller.rb), the shared [`TwoFactorVerification`](../../app/controllers/concerns/two_factor_verification.rb) concern, and [`TwoFactorAuth`](../../config/initializers/two_factor_auth.rb), the initializer that holds the temporary user, challenge, return path, and completion state. SMS send and resend lifetimes are in [`TwoFactor::SmsLoginChallenge`](../../app/services/two_factor/sms_login_challenge.rb) and [`TwilioVerifyService`](../../app/services/twilio_verify_service.rb).

Two ordering details matter. JSON and WebAuthn completion must create the session before clearing the challenge. Resolving the temporary MFA user rechecks `public_login_active?`, so an account retired mid-sign-in cannot finish verifying.

The public sign-in locale — the language and region setting — is carried into MFA redirects and verification URLs. It does not come from the matched account. The method chooser and the security-key, authenticator-app, and SMS verification pages support English and Spanish, including code errors and SMS send and resend feedback.

Credential lookup, challenge, and signature failures return the same JSON 422 response and `verification_failed` code with translated retry guidance. These JSON responses go to the verification pages' own browser scripts, which request JSON; 422 means the request was rejected. Server logs retain the failure category, without sending verifier details to the browser.

A verified key followed by a session creation failure returns `session_failed` with guidance to sign in again. If the temporary MFA user no longer resolves, verification returns `user_session` with the same sign-in guidance. JSON verification failures use 422 regardless of locale. Non-JSON HTTP failures produce a status-only console diagnostic and generic user feedback.

WebAuthn enrollment uses **Maryland Accessible Telecommunications** as its display name. The [WebAuthn initializer](../../config/initializers/webauthn.rb) configures the RP ID (the site identity the credential is bound to) and the allowed origins separately. These define the credential scope and accepted origins.

TOTP provisioning URIs retain `MatVulcan` as the issuer, a deliberate exception to the public program name. A provisioning URI is the code an authenticator app scans. The issuer labels new enrollments. Changing it does not rename existing authenticator entries or alter TOTP codes.

The request-locale wrapper covers public sign-in and MFA verification, not setup or credential enrollment. Those screens keep their existing English and default-locale behavior. Enrollment and verification share invalid-code, expired-code, attempt-limit, and provider-error translations in `two_factor_verification`. The pending SMS enrollment service still owns its English duplicate-send message. Authenticated dashboards do not use the public request locale.

## Password reset and account access

[`PasswordsController#create`](../../app/controllers/passwords_controller.rb) resolves the account and delivery route together through `User.find_for_account_access`. An email selects email delivery. A phone selects SMS only when that same email-backed account has an SMS-capable number. Matched, unmatched, undeliverable, and throttled requests all produce the same public confirmation.

Links are built against the [configured public host](../../app/services/canonical_public_url_options.rb) rather than the request host. Production refuses the `example.com` placeholder.

The `:password_reset` token expires in **20 minutes**. It is derived from the password digest (a one-way fingerprint of the value), the normalized login email, and the normalized phone. Changing any of those invalidates outstanding links, including one already texted to a number a merge later removed. Reformatting a phone or email cosmetically does not, since normalization absorbs it. Redemption re-resolves the token under lock before writing the password. Signed-in and forced changes go through [`Users::PasswordUpdateService`](../../app/services/users/password_update_service.rb).

Issuing a reset link deliberately sits outside the merge lock. A racing contact change can therefore send a now-dead link to an old destination. Token invalidation and locked redemption are what make that safe. See the [merge integrity boundary](../development/service_architecture.md#merge-integrity-lock-boundary).

## Lost security keys

[`AccountRecoveryController`](../../app/controllers/account_recovery_controller.rb) accepts the same eligible identifiers and files a request for staff. A partial unique index — a database rule that blocks duplicates only where a condition holds — allows one pending [`RecoveryRequest`](../../app/models/recovery_request.rb) per user. Repeat submissions return the same public confirmation and reuse the pending request.

[`Admin::RecoveryRequestsController`](../../app/controllers/admin/recovery_requests_controller.rb) approves the request and removes **WebAuthn credentials only**. TOTP and SMS survive. Approval rolls back if the notification record cannot be created or reports an immediate delivery error. A successfully enqueued email still proves nothing about later delivery. The admin **Delete MFA tokens** action is the broader one: it removes all factor types plus sessions ([admin tools](../development/user_management_features.md#admin-tools)).

## Public copy constraints

[Registration](../../app/controllers/registrations_controller.rb) routes an exact email-backed match to sign-in and gives every other hard contact collision the same support-only message. That message must not reveal whether the matched record is email-backed, phone-only, admin-created, SMS-capable, or reachable at all. It must not echo the submitted email. It must not offer a sign-in or account-access call to action. Each of those would answer, by implication, a question about someone else's record.

The form may keep the person's own entered values for correction. Account-access requests hold the same line, with one confirmation for matched, unmatched, undeliverable, and throttled alike.

The constraint lives in translated copy as much as in the controllers. [Registration response tests](../../test/controllers/registrations_controller_test.rb) and [account-access tests](../../test/controllers/passwords_controller_test.rb) cover it.

## Unauthenticated requests

[`Authentication#authenticate_user!`](../../app/controllers/concerns/authentication.rb) answers by format. JSON callers get a 401 ("not signed in") with `Cache-Control: no-store` and `{ "error": "authentication_required", "sign_in_path": "/sign_in" }`. HTML and Turbo callers — Turbo updates page content without a full reload — get a redirect to sign-in, with the attempted GET or HEAD path stored for the return trip.

A JSON caller that silently retries will just fail again. If the page holds selected files, reloading it loses them, so the sign-in prompt belongs in the existing page.

[`AuthRateLimit`](../../app/services/auth_rate_limit.rb) owns failed sign-in, account-access, and recovery throttles. Its limits are backed by policy. Its keys and audit metadata hold identifier digests rather than raw identifiers. [`PublicAuditActor`](../../app/services/public_audit_actor.rb) attributes unauthenticated events to the configured system user. If that user is missing, it skips the event with a warning.

Provision `system@mdmat.org` during [initial account setup](../infrastructure/setup_and_maintenance.md#initial-accounts). Public requests do not create it. A registration that needs a duplicate-review case also depends on this actor and rolls back if it is absent.

MFA verification mostly writes Rails logs through `TwoFactorAuth` rather than `Event` rows. Attempt history is therefore not in the audit trail.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Loops back to MFA setup | The role requires a factor and `second_factor_enabled?` is false. Commonly an unverified SMS credential. |
| WebAuthn fails on a deployed host | [WebAuthn config](../../config/initializers/webauthn.rb): production needs `APPLICATION_HOST` and uses its HTTPS origin. `WEBAUTHN_RP_ID` overrides. Development is `localhost`. |
| SMS not sent | [Twilio config](../../config/initializers/twilio.rb): `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_VERIFY_SERVICE_SID`, phone format, resend cooldown. |
| TOTP code rejected | Missing credential, secret decryption failure, or clock drift beyond 30 seconds. |
| Reset link stopped working | Expiry, a changed password, email, or phone, or an account no longer login-active. |

Tests simulate Twilio Verify and accept `123456`. Development falls back to the same simulation when Verify is unconfigured. Neither says anything about production SMS working.

## Tests

- [Root redirects](../../test/controllers/home_controller_test.rb) — role destinations, expired sessions, password/MFA gates, and public sign-in links.
- [Sessions](../../test/controllers/sessions_controller_test.rb), [idle and absolute lifetime](../../test/models/session_test.rb), [real-cookie activity flow](../../test/integration/session_activity_test.rb), [enrollment policy](../../test/controllers/mfa_enrollment_policy_test.rb)
- [Password sign-in and registration cookie attributes](../../test/integration/session_cookie_test.rb) — browser-session lifetime, HttpOnly, SameSite=Lax, and the stored 24-hour deadline.
- [WebAuthn verification](../../test/controllers/two_factor_authentication_webauthn_test.rb), [SMS selection](../../test/controllers/two_factor_authentication_sms_selection_test.rb)
- [Password reset](../../test/controllers/passwords_controller_test.rb), [concurrent resets](../../test/controllers/passwords_controller_concurrency_test.rb)
- [Recovery requests](../../test/controllers/account_recovery_controller_test.rb), [admin approval](../../test/controllers/admin/recovery_requests_controller_test.rb)
- [Twilio Verify](../../test/services/twilio_verify_service_test.rb)

The authentication test helpers bypass parts of sign-in and MFA. Tests of those boundaries therefore have to drive the real flow ([testing and debugging](../development/testing_and_debugging_guide.md)).
