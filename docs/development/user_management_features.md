# User Management Features

This document describes the current user creation, duplicate detection, admin user management, and test helper patterns.

## 1 · High-Level Flow

```text
Public signup
  -> RegistrationsController#create
  -> DuplicateDetectionService
  -> User / Users::Constituent
  -> DuplicateReviewCases::CreateService when soft review is needed
  -> UserProfile / UserAuthentication / UserGuardianship / UserEmailSearch
  -> Users::RegistrationConfirmationService

Admin user management
  -> Admin::UsersController
  -> Users::FilterService
  -> admin/users views
  -> AuditEventService for sensitive actions
```

Admin user pages run through `Admin::BaseController`, which requires an authenticated administrator and sets `Current`.

## 2 · Main Entry Points

| Area | Path | Current behavior |
|------|------|------------------|
| Routes | `config/routes.rb` | Defines `sign_up`, profile/password routes, `admin/users`, and member routes such as `mfa_tokens_admin_user_path`, `update_role_admin_user_path`, and `history_admin_user_path`. |
| Public signup | `app/controllers/registrations_controller.rb` | Builds a `Users::Constituent`, redirects exact email-backed account duplicates to sign-in, blocks stored-phone contact collisions with support-only copy, flags name+DOB matches for review, creates the session only when registration is safe, and sends registration confirmation. Phone-only and address-only paper records must not become public portal identities. |
| Admin users | `app/controllers/admin/users_controller.rb` | Lists, filters, shows, edits, creates, role-converts, capability-updates, deletes MFA tokens, deletes users, and serves guardian/dependent helper endpoints. |
| User model | `app/models/user.rb` | Base STI model. Includes authentication, roles/capabilities, profile validation, contact predicates, guardian/dependent logic, and email search tokens. |
| Contact predicates | `app/models/concerns/user_contact_predicates.rb` | Canonical contact truth: `real_email?`, `real_phone?`, `sms_capable_phone?`, `portal_access_eligible?`, and `email_backed_public_portal_account?`. `portal_access_eligible?` is stored-contact truth; `email_backed_public_portal_account?` is the public self-service gate. |
| Profile concern | `app/models/concerns/user_profile.rb` | Normalizes email and phone, declares encrypted fields, validates contact uniqueness and phone format, allows NULL email/phone in paper context, and logs profile changes. |
| Authentication concern | `app/models/concerns/user_authentication.rb` | Owns password/session behavior and WebAuthn, TOTP, and SMS credential associations. |
| Guardian concern | `app/models/concerns/user_guardianship.rb` | Owns guardian/dependent associations, effective contact methods, and guardian access checks. |
| Email search concern | `app/models/concerns/user_email_search.rb` | Stores HMAC email-search tokens for admin search, including dependent email and guardian fallback email search. |
| Constituent subclass | `app/models/users/constituent.rb` | Adds application/evaluation associations and exposes duplicate-query helpers used by `DuplicateDetectionService`. |
| Portal dependent creation | `app/controllers/constituent_portal/dependents_controller.rb` | Creates new dependents for signed-in guardians, blocks exact contact collisions before persistence, and opens duplicate-review cases for soft matches after the dependent and guardian relationship are persisted. |
| Duplicate detection | `app/services/duplicate_detection_service.rb` | Owns exact contact and soft name+DOB/address signal evaluation for public registration, portal dependent creation, admin quick-create, and paper self/guardian/dependent creation contexts. |
| Duplicate review cases | `app/services/duplicate_review_cases/create_service.rb` | Opens idempotent review cases after the subject user is persisted, stores sanitized candidate/metadata snapshots, sets `users.needs_duplicate_review`, and logs the case-opened event. |
| Admin filtering | `app/services/users/filter_service.rb` | Applies admin users search, role, needs-review, relationship, and sorting filters. |
| User creation service | `app/services/applications/user_creation_service.rb` | Creates or reuses constituent users for paper/admin flows. Email-backed portal users (`email_backed_public_portal_account?`) get internal forced-change account setup, but raw passwords are not returned; phone-only and address-only users get internal passwords only and no email-backed portal setup. Phone-only lookup works when email is absent; phone lookup is skipped when primary email is system-generated. |
| Admin views | `app/views/admin/users/index.html.erb`, `app/views/admin/users/_users_table.html.erb`, `app/views/admin/users/show.html.erb` | Render the user list, duplicate-review badge/filter, role/capability controls, guardian/dependent detail, MFA token deletion, and user deletion controls. |
| Duplicate review workflow | `app/controllers/admin/duplicate_reviews_controller.rb`, `app/views/admin/duplicate_reviews/` | Active-case queue, state filter, grouped record comparison, one-outcome review form, audited return-to-review action, and same-person merge. |
| Duplicate resolution service | `app/services/duplicate_review_cases/resolution_service.rb` | Records one terminal or nonterminal outcome, enforces outcome prerequisites, recomputes the review flag from every pending state, and writes its audit event transactionally. |
| Same-person merge service | `app/services/users/duplicate_merge_service.rb` | Merges a duplicate constituent into a canonical survivor with explicit contact/delivery choices and one audit event. |

## 3 · Signup And Duplicate Handling

### 3.1 Exact account matches

Email and phone are stored with deterministic Rails encryption so exact lookups still work. Before validation, `UserProfile` normalizes email with `User.normalize_email` and formats 10-digit US phone numbers as `XXX-XXX-XXXX`.

`RegistrationsController#create` calls `DuplicateDetectionService` with context `:public_registration` before saving. Exact contact matches are hard blockers:

- matching email on an email-backed portal account redirects to sign-in with clear copy instead of creating another user; signup does not authenticate, create a session, send an account-access link, create a review case, set duplicate booleans, write audit rows, or include the submitted email in the redirect URL or flash copy
- matching phone or matching a non-portal email contact renders the signup page with support-only copy and no sign-in CTA because the contact may belong to a phone-only or address-only paper/admin record
- duplicate signup copy does not offer account-access delivery from the registration page and must not reveal whether a phone match was email-backed, phone-only, paper/admin-created, text-capable, or delivery-capable
- `PasswordsController#create` uses the same email-backed resolver: SMS is sent only when the matched account has `real_email?` and `sms_capable_phone?`; all outcomes show the same public confirmation (delivery details stay in audit logs only)
- conflicting matches, where submitted email and phone belong to different users, prioritize the email-backed sign-in redirect and save nothing from the attempted signup
- phone matching a non-email-backed paper/admin record renders the same support-only panel as other phone contact collisions and creates no portal account. The submitted phone remains owned by the paper/admin record; public copy must not reveal that the match was phone-only, paper/admin-created, text-capable, or delivery-capable.

All public registration hard blocks return before persistence, so they create no user, session, duplicate-review case, audit row, or duplicate-review boolean side effect.

`UserProfile` also validates unique email and phone through `User.exists_with_email?` and `User.exists_with_phone?`. The database has unique indexes on `users.email` and on non-null `users.phone` values.

Blank phone numbers are allowed. Non-blank phones must normalize to a 10-digit US number when the phone changes.

### 3.1.1 Contact predicates and paper intake paths

`UserContactPredicates` defines the shared vocabulary:

| Method | Meaning |
|--------|---------|
| `real_email?` | Present, valid format, not `@system.matvulcan.local` |
| `real_phone?` | Present, valid 10-digit US, not synthetic `000-…` prefix |
| `sms_capable_phone?` | `real_phone?` and `phone_type == 'text'` |
| `portal_access_eligible?` | `real_email?` or `real_phone?` for stored-contact truth |
| `email_backed_public_portal_account?` | `real_email?` only — required for public portal sign-in, account access, and paper/admin portal setup markers |

Paper/admin intake supports:

- **Phone-only adults** — `no_email_address=1` strips email; user may still be `portal_access_eligible?` for record truth, but is **not** an email-backed portal account. No forced-change portal setup, quick-create markers, or account-created notices.
- **Address-only adults** — `no_email_address=1` and `no_phone_number=1` store NULL email/phone, force letter delivery, set `phone_type` to `letter`, and create users without exposed/temp passwords or portal access.
- **Dependents** — synthetic primary email/phone remain dependent-only placeholders; adults never receive synthetic contacts when NULL is valid. Notifications and display use **effective contact** helpers (`effective_email`, `effective_phone`, `effective_phone_type`, `effective_communication_preference`), which prefer dependent-owned contact fields and fall back to the managing guardian for communication only—not for portal login identifiers.

Physical address is enforced at the operation that needs it, not at sign-in. An application draft may be saved while an address is incomplete, but online submission requires street, city, state, and ZIP through `ApplicationForm`, with a final guard in canonical `Application#submit!` for direct submission callers. Letter preference requires the same complete mailing address through `UserProfile#validate_address_for_letter_preference`, and delivery resolvers also refuse a letter route without a mailing address. `email_backed_public_portal_account?` remains a real-email predicate; address completeness never grants portal access or makes an otherwise valid ongoing sign-in fail.

Admin display helpers (`display_contact_email`, `display_contact_phone`) hide synthetic values and show “No email on file” / “No phone on file”.

### 3.1.2 Contact concepts and account-created notices

| Concept | Source of truth |
| --- | --- |
| Stored contact truth | `portal_access_eligible?` from `real_email?` / `real_phone?` |
| Email-backed portal account | `email_backed_public_portal_account?` (`real_email?`) for sign-in, account access, paper portal setup, and account-created notices |
| Delivery route | `communication_preference` plus effective contact fallback for dependents |
| Record truth | Stored email/phone values and explicit paper no-contact flags |

Voucher-gated `account_created` notices are sent only when `FeatureFlag.enabled?(:vouchers_enabled)` and the paper application is voucher-fulfillment scope. Equipment-scope paper intake does not announce portal accounts the applicant cannot use.

Email-backed portal users created during paper intake get an internal initial password and `force_password_change`, but the raw password is not returned, cached, or stored in session. When an admin quick-creates a guardian in the same browser session, the session stores only a short-lived quick-created **email-backed** portal user id marker. `PaperApplicationsController#create` passes those user ids into `PaperApplicationService`; if a constituent needs help signing in, staff should use the existing account access link flow.

Persisted address-only constituents remain editable in admin user edit (name, address, letter preference) without requiring email. Normal admin edit cannot clear all contact information or keep email delivery without a real email; those transitions are reserved for paper intake with explicit no-contact flags.

Public portal self-registration requires a real email address. Phone remains optional; when supplied, the registrant must explicitly choose a phone type. The phone may serve as an alternate login identifier only if it can be stored on the email-backed portal account. If the submitted phone is already attached to another record, signup renders support-only copy and does not create a second portal user.

Signed-in portal constituents must keep a real email address on their profile. Phone-only and address-only records remain valid paper/admin records, but a public portal account cannot clear its email and become phone-only because public sign-in, account access, and recovery are email-backed.

### 3.2 Name and DOB review flag

Name+DOB and matching address/ZIP are soft duplicate signals, not signup blockers. Exact email and phone contact collisions are resolved by the `DuplicateDetectionService` hard-block outcomes above, not by setting `needs_duplicate_review`.

Soft duplicate handling is service-owned:

- `DuplicateDetectionService` evaluates exact contact matches and soft name+DOB/address signals. Public signup uses context `:public_registration`.
- Soft matches create `DuplicateReviewCase` rows through `DuplicateReviewCases::CreateService` after the subject user is persisted. Public registration uses source `:registration_soft_match`.
- `users.needs_duplicate_review` is set by `DuplicateReviewCases::CreateService`, not by controller helpers or model callbacks.
- Portal dependent creation uses context `:portal_new_dependent` and source `:portal_dependent`.
- Admin quick-create uses context `:admin_create` and source `:admin_create`.
- Paper self, guardian, and dependent creation use contexts `:paper_new_self`, `:paper_new_guardian`, and `:paper_new_dependent`; all paper-created review cases use source `:paper_intake`.

The flag is the real boolean column `users.needs_duplicate_review`, with default `false`.

The admin user index currently surfaces this flag in three ways:

- a highlighted count/link in the stats bar when flagged users exist
- a `Needs Review` filter backed by `Users::FilterService`
- a `Needs Review` badge and row highlight in `_users_table.html.erb`

### 3.2.1 Admin duplicate review and merge

Flagged duplicates are handled through an audited admin workflow. `DuplicateReviewCase` is the primary durable source when a case exists; a bare `users.needs_duplicate_review` row with no pending case is treated as a manual/legacy fallback.

- Entry points: `app/controllers/admin/duplicate_reviews_controller.rb`, reachable from the admin user index badge, the user show page, and a `Duplicate review pending` badge on the application show page (`Admin::DuplicateReviewsHelper#duplicate_review_pending_badge`) for the applicant or managing guardian, since staff working from an application would otherwise have no on-page signal that a review is pending.
- Queue (`index`): lists all active cases (`open`, `awaiting_information`, `security_review`) with source and workflow-state labels, supports state filtering, and separately shows manual/legacy flagged users that have no pending case.
- Detail (`show`): groups each record's facts by login identity, delivery route, record truth, applications, relationships, and auth artifacts, and shows candidate link state (current, already merged, or record no longer exists).

`DuplicateReviewCase.status` is the single workflow source of truth:

| State | Meaning | Flag / queue / merge behavior |
|-------------------|------------------|--------|
| `open` | Normal actionable review | Pending, queued, owns `needs_duplicate_review`, merge allowed. |
| `awaiting_information` | Staff need more evidence | Pending and queued; owns the flag; merge disabled until return to normal review. |
| `security_review` | Specialist security/fraud review is needed | Pending and queued; owns the flag; merge disabled. Does not suspend or deactivate either account. |
| `resolved_keep_separate` | Records were confirmed distinct | Terminal; moves no data. |
| `resolved_relationship` | A supported guardian/authorized relationship was confirmed after persistence | Terminal; never merges the two records. |
| `resolved_merged` | Same-person merge completed | Terminal; produced only by the merge service. |

The non-merge form has one required **Review outcome** control. `DuplicateReviewCases::ResolutionService` accepts only `outcome`, admin actor, nonblank rationale, and optional reviewed reason codes:

| Submitted outcome | Resulting state | Server-side requirement |
|-------------------|-----------------|-------------------------|
| `keep_separate` | `resolved_keep_separate` | Terminal; no user-owned data moves. |
| `authorized_relationship_confirmed` | `resolved_relationship` | A persisted supported `GuardianRelationship` must connect the subject and a recorded candidate. If none exists, the case stays open and staff are told to create it first. |
| `needs_more_information` | `awaiting_information` | Nonterminal; dedicated audit event; no user-owned data changes. |
| `fraud_or_security_review` | `security_review` | Nonterminal; dedicated audit event; no account restriction or user-owned data change. |

`same_person_confirmed` is rejected by `ResolutionService`. It is available only through `Users::DuplicateMergeService`, which performs the merge and sets `resolved_merged`. A nonterminal case must first use `DuplicateReviewCases::ResumeService` to return to `open`; that transition also requires an admin rationale and records `duplicate_review_case_returned_to_review`.

Current actor, rationale, and timestamp live in `reviewed_by`, `review_rationale`, and `reviewed_at`; terminal states additionally set `resolved_by` and `resolved_at`. `review_metadata` stores only structured codes and merge context, never raw contact values.

Flag/case sync is enforced in both directions: every outcome or merge recomputes the subject/canonical `needs_duplicate_review` flag from all pending states, a merge resolves the actionable pair-related pending cases that would otherwise be stranded on the retired duplicate, and the legacy `clear_flag` path refuses to clear a flag while any pending case remains. Awaiting-information or security-review cases block merging—including through a related case—until staff explicitly return them to normal review.

### 3.2.2 Same-person merge service

`Users::DuplicateMergeService` performs a same-person merge of one constituent record into a canonical survivor. It requires an admin actor, an actionable (`open`) review case, explicit same-person confirmation, a rationale, evidence/reason codes, and explicit contact and delivery choices. It locks both users and the related pending cases, preflights every blocker, performs all mutations with bang persistence inside one transaction, rolls back on failure, and emits exactly one `duplicate_user_merged` audit event.

A merged duplicate is deactivated (`status: inactive`) and points at its survivor through `users.merged_into_user_id`, with `merged_by_id` and `merged_at` recorded. It is never destroyed. `User#public_login_active?` rejects merged, inactive, and suspended records (treating legacy NULL status as active). It gates the auth-lookup helper (`find_by_login_identifier`), the password-reset token flows, and session-cookie creation (`_create_and_set_session_cookie`), which is the single chokepoint for both password sign-in and 2FA completion, so a duplicate retired mid-login cannot finish authenticating.

Merge inventory (decision per area):

| Area | Decision |
|------|----------|
| Applications | Transfer all duplicate-owned applications to the canonical user by FK repoint, preserving status, history, and audit. The admin UI always transfers all owned applications; per-application selection exists only at the service layer and is not wired into a form. If the canonical was the managing guardian of a transferred application, the managing guardian is cleared first so the merged record is never self-managed. Blocked if it would leave the canonical record with more than one active/blocking application. |
| Managed applications | Repoint `managing_guardian_id` to the canonical user, except for applications the canonical already owns, where the managing guardian is cleared instead (a record cannot manage its own application). |
| Guardian relationships (duplicate as guardian) | Transfer to canonical; blocked on a shared-dependent pair conflict. A direct guardian relationship between the two merged records (either direction) is dissolved rather than repointed, since a person cannot be their own guardian. |
| Guardian relationships (duplicate as dependent) | Transfer to canonical without copying effective guardian contact into stored record truth; blocked on a shared-guardian pair conflict. |
| Sessions | Duplicate sessions expire. |
| WebAuthn / TOTP / SMS credentials | Never transferred; canonical auth state preserved. |
| Password reset / recovery state | Duplicate reset token cleared on retirement; blocked if the duplicate has a pending recovery request; resolved recovery requests remain as retired-record history. |
| Secure request forms | Blocked if the duplicate is the recipient of an active bearer-link form. |
| Contact facts | Admin explicitly chooses the surviving email, phone, phone type, and address; synthetic or effective fallback values never become stored record truth. After those values are captured, the retired duplicate releases its primary email and phone so global identity lookup, duplicate detection, and unique indexes do not keep discarded contact live. A real surviving phone requires an explicit phone type. A missing or invalid per-field choice blocks the merge rather than silently defaulting to canonical. |
| Delivery route | Chosen explicitly and independently from login identity. A missing or invalid delivery choice blocks the merge rather than silently defaulting to canonical. |
| Login identity | The canonical account keeps a real email if it was email-backed; the merge is blocked if it would strand an email-backed portal account without a real email. |
| Duplicate review cases | The selected case and actionable pair-related pending cases resolve to `resolved_merged`; candidate snapshots and evidence are retained. A related awaiting-information or security-review case blocks merge until staff return it to normal review. |
| Evaluations / print queue | Evaluations follow their already-transferred application to the canonical user, so `evaluation.constituent` never drifts from `evaluation.application.user`. A still-pending print queue item transfers to the canonical user, since undelivered work needs a contactable owner; printed and canceled print queue items are historical and are never repointed. |
| Events / notifications / audit | Historical records are preserved (notifications are never repointed to the canonical user); the merge adds one `duplicate_user_merged` event, fingerprinted per merged-user id so two merges into the same canonical within the audit dedup window each keep their own event, rather than rewriting history. |

### 3.3 Paper applicant lookup and eligibility

Admin paper intake uses user lookup results as submission candidates, not just identity matches. Existing adults and dependents can be reused when the candidate is eligible for a new paper application.

Current paper candidate behavior includes:

- `paper_applicant_candidate?` marks users that can be considered by the paper intake flow.
- Admin paper search decorates candidates with waiting-period and `blocking_new_submission` state so the UI and service can block ineligible submissions.
- Existing adult self-applications require contact verification before the service writes a new application.
- Existing dependent submissions reuse the dependent and guardian relationship, apply the selected contact strategies before persisting contact updates, and still check waiting-period eligibility and `blocking_new_submission`.
- `adult_application_context` exposes on-file contact, eligibility, last application, income, and provider details so paper intake can prefill without silently changing verified contact information.

## 4 · Admin User Management

The admin user index supports:

- text search by first name, last name, full name, and email-search tokens
- role filters for administrator, evaluator, constituent, vendor, and trainer
- relationship filters for guardians and dependents
- `needs_review=true` filtering
- role conversion and explicit capability toggles from the users table

Email search uses `UserEmailSearchToken` rows. The tokens are HMAC digests, not stored plaintext email fragments. Dependent users are also searchable by their own `dependent_email` and, when that is blank, by a linked guardian's email.

The admin user show page displays:

- basic encrypted profile fields
- display contact email/phone (hides synthetic values)
- guardian/dependent relationships
- application history for the selected user
- edit, delete MFA tokens, and delete user actions

Admin-created users go through `UserServiceIntegration#create_user_with_service`, which calls `Applications::UserCreationService`. Email-backed portal constituents get internal forced-change account setup, `verified: true`, and `force_password_change: true`; raw passwords are not returned or stored for handoff. Address-only and phone-only users get internal passwords only and no email-backed portal account setup. Phone-only users may still be `portal_access_eligible?` for record truth but cannot use public portal sign-in or account access without a real email.

The admin user show page displays contact through `display_contact_email` and `display_contact_phone`, which hide synthetic values and show “No email on file” / “No phone on file” when appropriate.

## 5 · MFA And Destructive Admin Actions

Admins can remove all MFA credentials for another user from the admin user show page.

`Admin::UsersController#destroy_mfa_tokens` currently:

- responds to `DELETE /admin/users/:id/mfa_tokens`
- blocks the system user (`system@mdmat.org`)
- deletes the user's WebAuthn credentials, TOTP credentials, verified or unverified SMS credentials, and sessions
- logs `admin_user_mfa_tokens_deleted` with credential counts and deleted session count
- logs `admin_user_mfa_tokens_blocked` when the system-user guard blocks the action

This action is broader than security-key recovery. The recovery-request approval path in `Admin::RecoveryRequestsController#approve` only removes WebAuthn credentials for an approved recovery request.

Admins can also delete users from the admin user show page.

`Admin::UsersController#destroy` currently:

- responds to `DELETE /admin/users/:id`
- blocks deleting the system user
- blocks an admin from deleting their own account
- logs `admin_user_deletion_attempted` before deletion
- calls `destroy!` on the target user
- logs `admin_user_deleted` after success
- logs `admin_user_deletion_blocked` or `admin_user_deletion_failed` when deletion is blocked or raises an Active Record error

Deletion follows the model associations. For example, constituent applications are destroyed through `Users::Constituent`, while some foreign-key blockers can cause deletion to fail and redirect back with an alert.

## 6 · Guardian And Dependent Relationships

`GuardianRelationship` links one guardian user to one dependent user and requires `relationship_type`. A guardian/dependent pair can only have one relationship row, and a user cannot be their own guardian.

`UserGuardianship` provides:

- `guardian_relationships_as_guardian` and `dependents`
- `guardian_relationships_as_dependent` and `guardians`
- `managed_applications`
- `guardian?` and `dependent?`
- `editable_by_guardian`, `accessible_by_guardian`, and matching predicate helpers
- effective contact helpers that prefer dependent contact fields, then guardian fallback, then the user's own fields. These helpers are for communication routing and display only; portal auth continues to use primary stored contacts with synthetic-value guards.

Applications for dependents use `Application#managing_guardian_id` to record the managing guardian. Paper application details live in `docs/development/paper_application_architecture.md`.

## 7 · Test Selectors

The codebase uses `data-testid` attributes in selected views. There is not a global app-wide test-id contract for every form field.

Verified current examples include:

| Area | Example |
|------|---------|
| Flash messages | `app/views/shared/_flash.html.erb` renders `data-testid="flash-<type>"`. |
| Admin application queues | Evaluation and training queue partials use queue-level test IDs. |
| Medical certification panels | Admin application partials use IDs such as `medical-certification-section` and `medical-certification-upload-form`. |
| Secure request panels | Proof secure-request panels use `<proof_type>-proof-secure-request-forms-panel`. |
| Constituent dashboard | The training card uses `data-testid="training-card"`. |

Prefer the selectors already present in the view under test. Add new test IDs only when the accessible label/text is not stable enough for the interaction being tested.

## 8 · Factory Patterns

Current user factories live in `test/factories/users.rb`.

Common examples:

```ruby
create(:user)
create(:constituent)
create(:admin)
create(:evaluator)
create(:trainer)
create(:vendor_user)

guardian = create(:constituent, :with_dependent)
guardian = create(:constituent, :with_dependents, dependents_count: 3)
guardian = create(:constituent, :as_legal_guardian)
dependent = create(:constituent, :with_guardian)

create(:guardian_relationship,
       guardian_user: guardian,
       dependent_user: dependent,
       relationship_type: 'Parent')

create(:application, :for_dependent, guardian: guardian)
create(:application, :for_dependent,
       dependent_attrs: { first_name: 'John', last_name: 'Doe' })
```

Sequences cover normal email and phone uniqueness needs. When a test needs a specific contact value, keep email and phone unique unless the assertion is about uniqueness validation.

## 9 · Tests To Check

Focused test coverage for this area currently includes:

| Behavior | Test path |
|----------|-----------|
| Encrypted email/phone lookup and uniqueness | `test/models/user_encrypted_validation_test.rb` |
| User profile, guardian/dependent helpers, and contact validation | `test/models/user_test.rb` |
| Public signup exact duplicate/account-access behavior | `test/controllers/registrations_controller_test.rb` |
| Admin user show, MFA token deletion, user deletion, and admin JSON user creation | `test/controllers/admin/users_controller_test.rb` |
| Admin user search tokens and filter service | `test/models/user_email_search_token_test.rb`, `test/services/users/filter_service_test.rb` |
| Security-key recovery request approval | `test/controllers/admin/recovery_requests_controller_test.rb` |
| Same-person merge service (transfer, contact/delivery choices, rollback, audit dedup) | `test/services/users/duplicate_merge_service_test.rb` |
| Duplicate review outcomes, nonterminal state boundaries, relationship requirement, and transactional audit | `test/services/duplicate_review_cases/resolution_service_test.rb` |
| Return from awaiting/security state to normal review | `test/services/duplicate_review_cases/resume_service_test.rb` |
| Admin duplicate review queue, detail, resolve, and merge controller actions | `test/controllers/admin/duplicate_reviews_controller_test.rb` |
| Application-show duplicate-review-pending badge | `test/controllers/admin/applications_controller_test.rb` |

## 10 · Related Docs

- `docs/security/authentication_system.md`
- `docs/development/guardian_relationship_system.md`
- `docs/development/paper_application_architecture.md`
- `docs/features/notifications.md`
- `docs/features/audit_event_tracking.md`
