# User Management Features

This document describes the current user creation, duplicate detection, admin user management, and test helper patterns.

## 1 · High-Level Flow

```text
Public signup
  -> RegistrationsController#create
  -> User / Users::Constituent
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
| Public signup | `app/controllers/registrations_controller.rb` | Builds a `Users::Constituent`, blocks exact email/phone duplicates with an account-access prompt, flags name+DOB matches for review, creates the session, and sends registration confirmation. |
| Admin users | `app/controllers/admin/users_controller.rb` | Lists, filters, shows, edits, creates, role-converts, capability-updates, deletes MFA tokens, deletes users, and serves guardian/dependent helper endpoints. |
| User model | `app/models/user.rb` | Base STI model. Includes authentication, roles/capabilities, profile validation, guardian/dependent logic, and email search tokens. |
| Profile concern | `app/models/concerns/user_profile.rb` | Normalizes email and phone, declares encrypted fields, validates contact uniqueness and phone format, and logs profile changes. |
| Authentication concern | `app/models/concerns/user_authentication.rb` | Owns password/session behavior and WebAuthn, TOTP, and SMS credential associations. |
| Guardian concern | `app/models/concerns/user_guardianship.rb` | Owns guardian/dependent associations, effective contact methods, and guardian access checks. |
| Email search concern | `app/models/concerns/user_email_search.rb` | Stores HMAC email-search tokens for admin search, including dependent email and guardian fallback email search. |
| Constituent subclass | `app/models/users/constituent.rb` | Adds application/evaluation associations and a create-time name+DOB duplicate check. |
| Admin filtering | `app/services/users/filter_service.rb` | Applies admin users search, role, needs-review, relationship, and sorting filters. |
| User creation service | `app/services/applications/user_creation_service.rb` | Creates or reuses constituent users for paper/admin flows, generates temporary passwords, and marks new service-created users as verified with forced password change. |
| Admin views | `app/views/admin/users/index.html.erb`, `app/views/admin/users/_users_table.html.erb`, `app/views/admin/users/show.html.erb` | Render the user list, duplicate-review badge/filter, role/capability controls, guardian/dependent detail, MFA token deletion, and user deletion controls. |

## 3 · Signup And Duplicate Handling

### 3.1 Exact account matches

Email and phone are stored with deterministic Rails encryption so exact lookups still work. Before validation, `UserProfile` normalizes email with `User.normalize_email` and formats 10-digit US phone numbers as `XXX-XXX-XXXX`.

`RegistrationsController#create` calls `duplicate_account_match?` before saving:

- matching email or phone renders the signup page with an account-access prompt instead of creating another user
- matching email can offer an account-access link by email
- matching text-capable phone can offer an account-access link by SMS
- conflicting matches, where email and phone belong to different users, show a support-contact prompt

`UserProfile` also validates unique email and phone through `User.exists_with_email?` and `User.exists_with_phone?`. The database has unique indexes on `users.email` and non-null `users.phone`.

Blank phone numbers are allowed. Non-blank phones must normalize to a 10-digit US number when the phone changes.

### 3.2 Name and DOB review flag

Name+DOB matching is a soft duplicate signal, not a signup blocker.

Current checks compare lowercased first name, lowercased last name, and exact `date_of_birth`:

- `RegistrationsController#potential_duplicate_found?` runs during public signup.
- `Users::Constituent#check_for_duplicates` runs before validation on create.
- `Admin::UsersController#potential_duplicate_found?` runs after admin JSON user creation and excludes the newly persisted user.

The flag is the real boolean column `users.needs_duplicate_review`, with default `false`.

The admin user index currently surfaces this flag in three ways:

- a highlighted count/link in the stats bar when flagged users exist
- a `Needs Review` filter backed by `Users::FilterService`
- a `Needs Review` badge and row highlight in `_users_table.html.erb`

Important distinction: the current admin surface flags and filters possible duplicates. It does not provide a merge or ignore workflow.

### 3.3 Paper applicant lookup and eligibility

Admin paper intake uses user lookup results as submission candidates, not just identity matches. Existing adults and dependents can be reused when the candidate is eligible for a new paper application.

Current paper candidate behavior includes:

- `paper_applicant_candidate?` marks users that can be considered by the paper intake flow.
- Admin paper search decorates candidates with waiting-period and `blocking_new_submission` state so the UI and service can block ineligible submissions.
- Existing adult self-applications require contact verification before the service writes a new application.
- Existing dependent submissions can reuse the dependent and guardian relationship while still checking contact strategy, waiting-period eligibility, and `blocking_new_submission`.
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
- effective email, stored phone, and relationship contact details
- guardian/dependent relationships
- application history for the selected user
- edit, delete MFA tokens, and delete user actions

Admin-created users go through `UserServiceIntegration#create_user_with_service`, which calls `Applications::UserCreationService`. New service-created constituents get a generated temporary password, `verified: true`, and `force_password_change: true`.

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
- effective contact helpers that prefer dependent contact fields, then guardian fallback, then the user's own fields

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

## 10 · Related Docs

- `docs/security/authentication_system.md`
- `docs/development/guardian_relationship_system.md`
- `docs/development/paper_application_architecture.md`
- `docs/features/notifications.md`
- `docs/features/audit_event_tracking.md`
