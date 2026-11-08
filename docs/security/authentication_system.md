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

The signed `session_token` cookie carries a random 44-character token. The session row stores only its SHA-256 digest; [`Authentication`](../../app/controllers/concerns/authentication.rb) digests the verified cookie value for lookup on later requests. Raw tokens are available in memory when issued, never stored in the session table. The digest cutover revokes existing sessions rather than retaining a raw-token compatibility reader. Sign-out deletes the session, the cookie, and any pending MFA state.

Session resolution also checks `public_login_active?`. An existing session for an inactive, suspended, or merged account is revoked and its browser authentication cleared on the next request, including JSON activity requests. New sign-in and pending MFA retain their existing activity checks.

## Recent authentication and contact changes

A completed sign-in records five minutes of recent authentication on the database session. [`Users::ReauthenticationService`](../../app/services/users/reauthentication_service.rb) requires the current password and an enrolled factor when the account has one, then rotates the session's bearer token. Checking a password without completing required MFA does not establish freshness. An in-flight request presenting the old bearer cannot inherit the rotated session's fresh grant. The five-minute window is application policy; a bearer stolen within that window remains a risk.

The grant records the user's `security_version`. Successful password, factor-membership, contact and recovery changes invalidate older pending authentication and contact authority through that version or the existing token binding. Protected writes recheck the live session, presented bearer and current version under the canonical user lock. Ordinary factor-use counters and profile edits do not advance authority.

Primary email, phone and recovery-relevant phone-type changes use [`Users::ContactChange`](../../app/services/users/contact_change.rb). Ordinary profile edits remain separate. Generic and vendor profile forms direct primary-contact changes to this flow. Staff-assisted corrections use the same promotion owner with recent administrator authentication and explicit identity/contact-association evidence. Supervised paper intake and duplicate merging retain their domain owners. Guardian/dependent and supervised paper contact writers advance the affected user's security version, invalidating pending MFA/contact proofs and older recent-authentication grants while preserving ordinary login sessions.

A [`ContactChangeRequest`](../../app/models/contact_change_request.rb) keeps the proposed destination pending for twenty minutes; the stored contact remains authoritative. An email change without MFA requires separate confirmation at the current and proposed addresses. With enrolled MFA, the current address receives a notice and the proposed address must be confirmed. SMS-capable phones require a correctly bound SMS proof. Voice/videophone numbers require staff assistance. Removing an optional phone requires recent authentication; enabling SMS recovery cannot silently bless an unverified number. Changing a contact does not retarget an independently enrolled SMS factor.

Email proof links use distinct purposes for the old and new address. GET only displays confirmation; a protected POST records proof. Promotion additionally rechecks current session authority, original expiry, request state and uniqueness. It consumes the request, advances account authority, records the audit and notice intent, and revokes all target-user sessions in one transaction. The user signs in again. An inaccessible old mailbox requires staff assistance through the approved recovery procedure. Staff must follow an agency-approved procedure; the attestation fields do not establish identity-assurance certification or prove that such a procedure has been approved.

Notices use encrypted snapshots of the old and proposed destinations. They do not resolve an old-address notice through the already-updated user or a guardian fallback. Failed proof delivery leaves the old contact active. A notice failure after committed promotion does not undo the contact change. `submitted` records provider acceptance, not confirmed delivery; `suppressed` records policy refusal. An ambiguous provider attempt records `unknown` and may be reconciled using the original correlation, without automatic provider resubmission while its outcome remains ambiguous. Pending, queued and error states can also be reconciled using the original correlation. Token pages use no-store/no-referrer responses. Signing protects integrity, not confidentiality, so token payloads contain request IDs rather than contact data. Bearer tokens use filtered query/body parameters, avoiding unfilterable URL path segments.

## Session lifetime

Sessions have a **30-minute idle limit** and retain the existing **24-hour absolute limit**. Activity can move the idle deadline but cannot extend the absolute deadline. Background document-scan status checks do not refresh the idle deadline. The login cookie has HttpOnly, production Secure, and explicit SameSite=Lax flags.

Password sign-in, MFA completion, and registration deliberately use a browser-session cookie without `Expires` or `Max-Age`. Registration follows the same cookie lifetime policy as subsequent sign-ins; it does not request a permanent cookie. The stored session still expires at the server deadlines if a browser restores the cookie. During deployment, inspect the HTTPS sign-in and registration responses to confirm `Secure`, `HttpOnly`, and `SameSite=Lax` on `session_token`.

Authenticated requests refresh `Session#last_active_at` only when its stored value is at least one minute old. This bounds database writes and makes the idle deadline conservative by up to one minute compared with the latest request. Expiry is checked again under the session row lock before an activity write; waiting for another request cannot revive an expired session. Activity refresh runs inside `authenticate_user!`, so inherited callback ordering cannot skip the expiry recheck. Public actions that skip authentication do not refresh activity.

Pages for fully signed-in users record genuine typing and interaction through an authenticated, CSRF-protected session-activity POST, at most once a minute. The warning and **Keep working** action cover all roles, with English or Spanish copy. Background scan polling, warning timers, and session-status GETs do not renew the session. The browser checks the server's deadlines when the page opens or regains focus and before showing a five-minute warning. **Keep working** renews idle time while the session remains valid; the absolute limit still requires another sign-in. If the session expires, the page keeps its visible form input and blocks submission so users can copy unfinished work. This does not save a draft or guarantee that signing in restores the form.

Apply [the session migration](../../db/migrate/20261022173000_add_last_active_at_to_sessions.rb) with the rest of the schema before first launch. It clears stored sessions, requiring anyone signed in on an existing instance to sign in once more. New sessions record activity at creation. An expired protected request clears browser authentication and pending session state. JSON receives the no-store 401 response described below; HTML and Turbo return to sign-in with an English or Spanish expiry alert. The redirect uses a supported request locale, then the expired session user's effective locale, then the default. An anonymous request instead receives a generic sign-in alert in its supported request locale.

Five recorded password failures lock the account for an hour ([`UserAuthentication`](../../app/models/concerns/user_authentication.rb)). This lockout is separate from request throttling. The account row lock serializes failed-login and sign-in writes, and the failure count and lock time change in one write that ignores profile validation. Checking the lock writes nothing: an expired lock is cleared by the next failed login or sign-in, and the next failure after expiry starts a new count. The shared session creator, used by password sign-in, second-factor completion, in-session password change, and registration, re-checks the lock under the account lock before saving the session, so a locked account gets no session even if the lock landed after its password step. A session that cannot save rolls the sign-in bookkeeping back. A locked account that changes its password while signed in keeps the lock: the change succeeds, the session ends at sign-in, and the notice says sign-in is paused for the lock duration. Only the person holding the signed-in session sees that notice; the sign-in screen keeps its generic copy, so it does not reveal whether an account is locked.

`CleanupExpiredSessionsJob` removes expired session rows daily in batches of 500. Its SQL predicate encodes the same idle/absolute deadlines as `Session#expired?`, including an absent absolute deadline, and rechecks both against current values in the deletion statement. A session refreshed while cleanup waited is retained. This removes session rows only; it changes neither timeout policy nor retained user/audit history.

## Second factors

Administrators, evaluators, trainers, and vendors must enroll; constituents may. [`ApplicationController#enforce_required_mfa_enrollment`](../../app/controllers/application_controller.rb) redirects a required role with no enabled factor into setup. `second_factor_enabled?` counts a WebAuthn credential, a TOTP credential, or a **verified** SMS credential. An unverified SMS credential is why an account can loop back to setup.

| Factor | Stored and verified |
| --- | --- |
| WebAuthn | WebAuthn is the browser standard behind security keys and passkeys. [`WebauthnCredential`](../../app/models/webauthn_credential.rb): credential ID, encrypted public key, sign count. Verification checks the session challenge and updates the count. |
| TOTP | TOTP is the time-based code from an authenticator app. [`TotpCredential`](../../app/models/totp_credential.rb): encrypted server-generated secret. Verification allows 30 seconds of clock drift either way and rejects an already accepted time step. |
| SMS | [`SmsCredential`](../../app/models/sms_credential.rb): phone and verification state. Twilio Verify checks a six-digit code; only challenge metadata is stored here. Local code entry lasts at most 10 minutes, with a 30-second resend cooldown and a separate provider-ownership deadline. |

Registration and verification are split across [`TwoFactorCredentialsController`](../../app/controllers/two_factor_credentials_controller.rb), [`TwoFactorAuthenticationsController`](../../app/controllers/two_factor_authentications_controller.rb), the shared [`TwoFactorVerification`](../../app/controllers/concerns/two_factor_verification.rb) concern, and [`TwoFactorAuth`](../../config/initializers/two_factor_auth.rb), the initializer that holds the temporary user, challenge, return path, and completion state. SMS send and resend lifetimes are in [`TwoFactor::SmsLoginChallenge`](../../app/services/two_factor/sms_login_challenge.rb), [`TwilioVerifyService`](../../app/services/twilio_verify_service.rb) and [`SmsVerificationAttempt`](../../app/models/sms_verification_attempt.rb).

HTML and JSON verification share `ApplicationController#complete_two_factor_authentication`. It captures the return path, creates the session before clearing the challenge, and returns the destination to the format-specific responder. A refused session aborts pending authentication in both formats. Resolving the temporary MFA user rechecks `public_login_active?`, so an account retired mid-sign-in cannot finish verifying. The password-bound pending sign-in token expires after 10 minutes; a late second factor requires a fresh password step.

TOTP enrollment keeps a user-bound pending secret in the encrypted Rails session for ten minutes. Refresh and an invalid-code retry reuse it without extending its expiry; submitted secrets are ignored. Expiry starts a new setup and asks the user to scan the new QR code. Successful enrollment consumes the matched code step. Sign-in stores that same matched timestamp, including a drift-ahead match, and only accepts a later step. A code just used for enrollment cannot also complete sign-in or reauthentication. Repeated enrollment requests for the same pending secret reuse the saved credential under the account lock. If duplicate credentials already hold the same secret, sign-in checks its latest consumed step and consumes the matched step on every copy.

TOTP permits five failed guesses per account in a 15-minute window starting with the first failure. The account row lock serializes checks and failure writes across browsers, IP addresses, and application workers. Attempt and reset bookkeeping writes only its auth fields and timestamp, independently of profile validation and callbacks. Exhaustion clears pending browser state; signing in with the password again cannot reset the account's budget. A successful TOTP check clears earlier failures, and the next attempt after the window ends starts a new budget. The lockout event is recorded after commit so an audit failure cannot reopen guesses. Verification submissions also share Rails' native limit of 30 per minute per IP address across the controller's verification actions. That cache-backed limit returns JSON 429 or redirects HTML/Turbo callers to sign-in with translated guidance.

The public sign-in locale — the language and region setting — is carried into MFA redirects and verification URLs. It does not come from the matched account. The method chooser and the security-key, authenticator-app, and SMS verification pages support English and Spanish, including code errors and SMS send and resend feedback.

Credential lookup, challenge, and signature failures return the same JSON 422 response and `verification_failed` code with translated retry guidance. These JSON responses go to the verification pages' own browser scripts, which request JSON; 422 means the request was rejected. Server logs retain the failure category, without sending verifier details to the browser.

A verified key followed by a session creation failure returns `session_failed` with guidance to sign in again. If the temporary MFA user no longer resolves, verification returns `user_session` with the same sign-in guidance. Factor-validation JSON failures use 422 regardless of locale; the IP request limit uses 429. Non-JSON HTTP failures produce a status-only console diagnostic and generic user feedback.

Missing or cleared pending MFA state makes a JSON security-key options request return 401; HTML and Turbo navigation redirect to sign-in. The key page uses its rendered English or Spanish sign-in guidance for that 401 without reading server error details. Reactivating an account does not restore cleared pending state: start again with password sign-in before another verification attempt.

WebAuthn enrollment uses **Maryland Accessible Telecommunications** as its display name. The [WebAuthn initializer](../../config/initializers/webauthn.rb) configures the RP ID (the site identity the credential is bound to) and the allowed origins separately. These define the credential scope and accepted origins.

TOTP provisioning URIs retain `MatVulcan` as the issuer, a deliberate exception to the public program name. A provisioning URI is the code an authenticator app scans. The issuer labels new enrollments. Changing it does not rename existing authenticator entries or alter TOTP codes.

The request-locale wrapper covers public sign-in and MFA verification, not setup or credential enrollment. Those screens keep their existing English and default-locale behavior. Enrollment and verification share invalid-code, expired-code, attempt-limit, and provider-error translations in `two_factor_verification`. The pending SMS enrollment service still owns its English duplicate-send message. Authenticated dashboards do not use the public request locale.

## Password reset and account access

New passwords require at least **12 characters**, the chosen product policy for every role. `UserAuthentication::PASSWORD_MIN_LENGTH` owns the minimum; server validation, new-password fields, and English/Spanish hints use it. Sign-in and current-password confirmation do not apply a new minimum to an existing password.

[`PasswordsController#create`](../../app/controllers/passwords_controller.rb) resolves the account and delivery route together through `User.find_for_account_access`. An email selects email delivery. A phone selects SMS only when that same email-backed account has an SMS-capable number. Matched, unmatched, undeliverable, and throttled requests all produce the same public confirmation.

Links are built against the [configured public host](../../app/services/canonical_public_url_options.rb) rather than the request host. Production refuses the `example.com` placeholder.

The `:password_reset` token expires in **20 minutes**. It is derived from the password digest (a one-way fingerprint of the value), the normalized login email, and the normalized phone. Changing any of those invalidates outstanding links, including one already texted to a number a merge later removed. Reformatting a phone or email cosmetically does not, since normalization absorbs it. Redemption re-resolves the token under lock before writing the password. Signed-in and forced changes go through [`Users::PasswordUpdateService`](../../app/services/users/password_update_service.rb).

A saved password change revokes the account's existing login sessions in the same transaction. It also invalidates unfinished MFA sign-ins: the pending browser state carries a signed token bound to the password salt. TOTP, SMS, and security-key verification check that token, and session creation checks it again under the shared user lock. A changed password requires a fresh password step even if the second factor was already accepted. Invalid input or a rolled-back change keeps existing sessions and pending sign-ins intact. An authenticated change replaces this browser's session after checking the new password under the shared user lock; existing welcome and MFA-enrollment routing still applies. If a replacement session cannot be created, the password change remains successful and the browser returns to sign-in. A successful token reset clears password lockout and failed password attempts, while preserving the TOTP failure budget. An invalid reset leaves the lock unchanged. Reset links return to sign-in and clear the resetting browser's authentication when it belongs to that account.

Issuing a reset link deliberately sits outside the merge lock. A racing contact change can therefore send a now-dead link to an old destination. Token invalidation and locked redemption are what make that safe. See the [merge integrity boundary](../development/service_architecture.md#merge-integrity-lock-boundary).

## Registration

[`RegistrationsController`](../../app/controllers/registrations_controller.rb) first accepts only an email and request-selected language. For syntactically valid addresses, known and unknown accounts receive the same verification-mail path and public confirmation. Throttling, suppression and issuance failure do not reveal which case occurred. No user, login session or password is created at this stage, and an old full-form POST cannot preselect a password or phone.

[`RegistrationVerification`](../../app/models/registration_verification.rb) stores the encrypted normalized email and an immutable sixty-minute deadline. Queued mail carries a request reference. The mailer creates a purpose-bound signed ID with that original absolute deadline and skips an expired or consumed request; its email states the actual expiration date, time and time zone. A repeated initiation may issue a new request without mutating an earlier row or revoking its valid link; each row retains its own original deadline. GET with the link renders the completion form without consuming it. No account-specific guidance is shown before possession of that contact's proof.

The check-email page explains delivery delays, spam filtering and expiry, and offers resend, address correction and ordinary account-access links. The encrypted Rails browser session retains the submitted address for those form actions; it conveys no verified-contact or sign-in authority. The address is excluded from flash and redirect URLs. Resend uses the same issuance path and budgets as the initial request.

[`Users::RegistrationCompletion`](../../app/services/users/registration_completion.rb) takes the email from the locked proof, accepts the password/profile only after proof, and ignores submitted replacement email or phone values. An existing account is directed to ordinary sign-in/account access without being authenticated, reused or modified. A new account and any required soft-duplicate review case commit with proof consumption, or neither commits. Duplicate-query or required-review failure cannot fall back to unchecked creation. Database uniqueness remains the final collision boundary. A flagged new account retains the existing final-submission gate until staff resolves its review.

After committed creation, the canonical session issuer checks the newly chosen password. A later session or welcome-notice failure is reported as follow-up failure after account creation, rather than as rollback. Optional phone addition happens afterward through verified contact change.

## Lost security keys

[`AccountRecoveryController`](../../app/controllers/account_recovery_controller.rb) accepts eligible identifiers and files a request for staff. A partial unique index allows one pending [`RecoveryRequest`](../../app/models/recovery_request.rb) per user. Repeat submissions reuse the pending request and return the same public confirmation. The public request itself deletes no credentials and grants no account authority.

[`Admin::RecoveryRequestsController`](../../app/controllers/admin/recovery_requests_controller.rb) opens an identity-verification form. [`RecoveryRequests::Approve`](../../app/services/recovery_requests/approve.rb) requires a different active administrator, a live recently authenticated session, and explicit completed verification with a method, result and bounded nonsecret reference. Staff must follow the approved agency process; an administrator role or checkbox is not a substitute for the real-world check. Availability when a second administrator is absent must be handled through an approved operational process.

Approval removes **WebAuthn credentials only** and preserves TOTP, SMS, the password and contact values. It revokes all target-user sessions, cancels pending contact requests and advances the user's security version. Its audit records the approving actor, verification record, removed internal credential IDs/count, retained factor counts and revoked-session count, without credential secrets or public keys. These changes, the resolved request, audit and required notice intent share one transaction. Failed verification or pre-commit persistence failure leaves the destructive changes uncommitted.

Notice transport occurs after commit. An enqueue or delivery failure leaves recovery approved and is shown separately on the admin detail. Its retry action reuses the durable notice intent without repeating approval or deletion; queue acceptance does not prove delivery. The admin **Delete MFA tokens** action remains broader: all factor types plus sessions ([admin tools](../development/user_management_features.md#admin-tools)). Key-only loss is the scope here; a stolen phone/number or broader compromise requires the corresponding approved remediation process. Retaining TOTP/SMS does not certify phishing resistance or an assurance level.

## Public copy constraints

Registration initiation, account access and recovery use request-selected locale and neutral public outcomes. They do not reveal account existence, record source, SMS capability, delivery success or a raw submitted contact in flash or redirect URLs. The form may retain the person's own input for correction. The old pre-proof duplicate-email sign-in exception is removed; account-specific guidance requires proof of that exact email first.

[Registration initiation tests](../../test/controllers/registrations_controller_test.rb), [completion tests](../../test/controllers/registration_verifications_controller_test.rb) and [account-access tests](../../test/controllers/passwords_controller_test.rb) describe these boundaries. Verification results for a release must be assessed separately from the presence of tests.

## Unauthenticated requests

[`Authentication#authenticate_user!`](../../app/controllers/concerns/authentication.rb) answers by format. JSON callers get a 401 ("not signed in") with `Cache-Control: no-store` and `{ "error": "authentication_required", "sign_in_path": "/sign_in" }`. HTML and Turbo callers — Turbo updates page content without a full reload — get a redirect to sign-in, with the attempted GET or HEAD path stored for the return trip.

A JSON caller that silently retries will just fail again. If the page holds selected files, reloading it loses them, so the sign-in prompt belongs in the existing page.

[`AuthRateLimit`](../../app/services/auth_rate_limit.rb) owns failed sign-in, account-access, recovery, registration, contact-change and shared SMS-send budgets. [`AuthRateLimitCounter`](../../app/models/auth_rate_limit_counter.rb) reserves capacity under a database uniqueness constraint and row lock, so shared-cache eviction cannot restore it. Policy-read or reservation failure refuses the protected issuance. Registration defaults are thirty requests per IP per hour and three per normalized recipient per hour across IPs; initiation and resend share those budgets. Keys and audit metadata contain keyed identifier digests rather than raw contacts/IPs. Proof-upload limits and Rails' native verification IP limit retain their separate cache-backed owners. [`PublicAuditActor`](../../app/services/public_audit_actor.rb) attributes unauthenticated events to the configured system user. Matched account-access and recovery-attempt events retain the account as their auditable subject, without attributing the request to its owner. If the system user is missing, the helper skips the event with a warning; public responses and throttling remain unchanged.

`bin/rails db:bootstrap` provisions `system@mdmat.org` ([bootstrapping an environment](../infrastructure/setup_and_maintenance.md#bootstrapping-an-environment)). Public requests do not create it. A registration that needs a duplicate-review case also depends on this actor and rolls back if it is absent.

MFA verification mostly writes Rails logs through `TwoFactorAuth`. Exhausting the durable TOTP account budget additionally records `two_factor_verification_rate_limited` through `PublicAuditActor`, with the account as the audit target rather than an authenticated actor. A missing system actor or audit-write failure is reported by that owner without reopening the durable account budget. Rails logs record factor-verification failures; WebAuthn lookup and verifier failures share a generic refusal reason. Submitted codes are filtered.

## SMS ownership and maintenance

Twilio may reuse a pending code for a destination. A local purpose label alone does not isolate provider state. [`SmsVerificationAttempt`](../../app/models/sms_verification_attempt.rb) reserves one current owner per Verify service and normalized destination, binding the purpose, account/browser context and expected provider SID. Different contexts cannot adopt a pending challenge. The application caps code entry at the lesser of ten minutes and the configured provider lifetime, uses a thirty-second send cooldown and five checks per local challenge, and reserves a shared destination send budget before provider I/O. Resending does not extend the original challenge deadline. Provider calls run outside the reservation transaction, with bounded HTTP timeouts; an ambiguous send may still have delivered.

A check establishes proof only for an approved response matching the service, SID, destination and channel. The service accepts exactly six decimal digits, so the deployed Verify service must use six-digit codes. A trusted send response must include its creation time. A missing provider verification or later 404 is not evidence of approval.

| Configuration | Required deployment contract |
| --- | --- |
| `TWILIO_VERIFY_TOKEN_LIFETIME_SECONDS` | Defaults to `600`; accepts `120`–`86400`. It must match the Verify service's actual token lifetime. Twilio's API does not expose the custom lifetime for automatic discovery. |
| Verify code length | Configure six digits to match the local verification contract. |

The separate `ownership_expires_at` initially covers the configured provider lifetime plus forty-five seconds of call uncertainty. A later trusted provider creation time can extend that ownership fence, without extending local code entry. Resends do not extend it. Exhaustion, terminal failure and local expiry retain ownership through the provider window; trusted approval can finish it. A longer provider lifetime therefore cannot allow another browser or purpose to adopt a still-live code. These guarantees depend on the deployed lifetime matching configuration; production settings and delivery require operational verification.

Daily cleanup in [`config/recurring.yml`](../../config/recurring.yml) prunes expired registration payloads and old authentication counters through [`PruneRegistrationVerificationsJob`](../../app/jobs/prune_registration_verifications_job.rb). Registration records are eligible one day after expiry; active counters are retained. [`PruneContactVerificationsJob`](../../app/jobs/prune_contact_verifications_job.rb) reconciles pending, error, or queued contact notice intents with their original delivery correlation while the request remains within seven days after expiry. Expired proof mail is skipped; unknown provider outcomes are not automatically resent. At seven days, it audits any unresolved completion-notice roles and states as `account_contact_notice_abandoned`, with reason `proof_payload_retention_expired`, before purging the encrypted request payload. A failed required audit prevents that purge. SMS attempts are eligible one day after their provider-ownership deadline, rather than after local code-entry expiry.

Cleanup removes purpose-specific payloads, not user or audit history. A job whose request has already been pruned cannot reconstruct its proof or notice from the remaining audit IDs. Expiry is checked at use, so delayed cleanup or a stopped worker does not extend proof authority. A backlog can retain data longer than its scheduled cleanup target and needs operational attention.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Loops back to MFA setup | The role requires a factor and `second_factor_enabled?` is false. Commonly an unverified SMS credential. |
| WebAuthn fails on a deployed host | [WebAuthn config](../../config/initializers/webauthn.rb): production needs `APPLICATION_HOST` and uses its HTTPS origin. `WEBAUTHN_RP_ID` overrides. Development is `localhost`. |
| SMS not sent | [Twilio config](../../config/initializers/twilio.rb): `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_VERIFY_SERVICE_SID`, phone format, resend cooldown. |
| TOTP code rejected | Already used code, missing credential, secret decryption failure, or clock drift beyond 30 seconds. |
| Reset link stopped working | Expiry, a changed password, email, or phone, or an account no longer login-active. |

Tests simulate Twilio Verify and accept `123456`. Development falls back to the same simulation when Verify is unconfigured. Neither says anything about production SMS working.

## Tests

- [Root redirects](../../test/controllers/home_controller_test.rb) — role destinations, expired sessions, password/MFA gates, and public sign-in links.
- [Sessions](../../test/controllers/sessions_controller_test.rb), [idle and absolute lifetime](../../test/models/session_test.rb), [real-cookie activity flow](../../test/integration/session_activity_test.rb), [enrollment policy](../../test/controllers/mfa_enrollment_policy_test.rb)
- [Password sign-in and verified-registration cookie attributes](../../test/integration/session_cookie_test.rb) — browser-session lifetime, HttpOnly, SameSite=Lax, and the stored 24-hour deadline.
- [WebAuthn verification](../../test/controllers/two_factor_authentication_webauthn_test.rb), [SMS selection](../../test/controllers/two_factor_authentication_sms_selection_test.rb)
- [TOTP replay and enrollment](../../test/integration/totp_replay_and_enrollment_test.rb) — drift-ahead replay across independent sign-ins, server-selected seeds, retry and fixed enrollment expiry.
- [MFA attempt budgets and pending-login expiry](../../test/integration/two_factor_attempt_limit_test.rb) — account limits across browsers/IPs, restart and expiry behavior, translated guidance, and the native IP throttle.
- [Password reset](../../test/controllers/passwords_controller_test.rb), [concurrent resets](../../test/controllers/passwords_controller_concurrency_test.rb)
- [Recovery requests](../../test/controllers/account_recovery_controller_test.rb), [admin approval](../../test/controllers/admin/recovery_requests_controller_test.rb), [recent authentication](../../test/controllers/reauthentications_controller_test.rb)
- [Registration initiation](../../test/controllers/registrations_controller_test.rb), [proof completion](../../test/controllers/registration_verifications_controller_test.rb), [completion races](../../test/services/users/registration_completion_concurrency_test.rb), [durable request budgets](../../test/services/auth_rate_limit_test.rb)
- [Twilio Verify](../../test/services/twilio_verify_service_test.rb)

The authentication test helpers bypass parts of sign-in and MFA. Tests of those boundaries therefore have to drive the real flow ([testing and debugging](../development/testing_and_debugging_guide.md)).
