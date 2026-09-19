# User Management

Applicants, guardians, and staff all live in the `users` table, separated by STI subclass.

Role decides what someone can do.

Stored contact decides how they can be reached.

Neither one decides whether they can sign in.

Duplicate review is the machinery for deciding whether two similar records are the same person.

[`User`](../../app/models/user.rb) itself is thin; the behavior is in concerns:

| Concern | Owns |
| --- | --- |
| [`UserProfile`](../../app/models/concerns/user_profile.rb) | Contact normalization and validation, encrypted fields, profile-change history |
| [`UserAuthentication`](../../app/models/concerns/user_authentication.rb) | Passwords, sessions, MFA credentials |
| [`UserRolesAndCapabilities`](../../app/models/concerns/user_roles_and_capabilities.rb) | Roles, plus separately assigned capabilities such as training and evaluation |
| [`UserGuardianship`](../../app/models/concerns/user_guardianship.rb) | Relationship queries and effective-contact resolution |

## Contact is not sign-in, and neither is delivery

A paper applicant with a phone and no email is a real constituent who can be contacted and served, and who has no portal account. The [contact predicates](../../app/models/concerns/user_contact_predicates.rb) keep the three questions apart:

| Method | Answers |
| --- | --- |
| `real_email?` / `real_phone?` | Is a usable value stored? Blank, invalid, and synthetic values are excluded. |
| `sms_capable_phone?` | Real phone with `phone_type: text`. |
| `portal_access_eligible?` | Whether either real contact exists. The name overpromises: it grants nothing. |
| `email_backed_public_portal_account?` | Whether a real primary email exists, which public access requires. |

Sign-in additionally requires `public_login_active?` — merged, suspended, and inactive records are out. [`User.find_by_login_identifier`](../../app/models/user.rb) will match on a real phone, but only for an account that also has a real email. Account-access delivery picks email or an SMS-capable phone independently of that.

Synthetic values are internal, never destinations: dependent emails ending `@system.matvulcan.local`, phones beginning `000`. Paper intake can also leave contact fields genuinely blank for phone-only or address-only constituents, and address-only records need a complete mailing address because letters are the only way to reach them.

A dependent's effective contact may resolve to a guardian's. That routes messages; it does not make the guardian's email the dependent's login.

### Editing contact later

[`UserProfile`](../../app/models/concerns/user_profile.rb) treats a profile edit differently from intake. A constituent editing their own portal profile keeps a real primary email. An ordinary admin edit cannot strip a constituent's last usable email or phone and turn them into an address-only record, though records already in that state stay editable with letter delivery and a full address. Email delivery needs a real email, and a dependent's valid delivery email satisfies that even when their primary is synthetic — again without granting portal access.

Deliberate no-contact transitions belong to paper intake, which asks for them explicitly. The [admin contact-edit tests](../../test/controllers/admin/users_controller_test.rb) pin the distinctions.

## How people get into the table

**Public registration.** [`RegistrationsController`](../../app/controllers/registrations_controller.rb) consults [`DuplicateDetectionService`](../../app/services/duplicate_detection_service.rb) before saving. An exact email match against an email-backed account sends the person to sign-in, and that outcome outranks a conflicting phone match; other exact collisions return a support-only message; a soft name/date-of-birth match registers the account and opens a review case in the same transaction. Registration requires a real email, and a phone, if given, must come with its type. Similarity is evidence for staff, never permission to take over an account.

**Paper and admin intake.** [`Applications::UserCreationService`](../../app/services/applications/user_creation_service.rb) creates constituents who may never use the portal. Email-backed accounts get an internal password plus a forced password change; no raw password is handed back for staff to read out. [`PaperIdentityReview`](../../app/services/applications/paper_identity_review.rb) separates contact collisions that block creation from candidates staff can judge, and the writers — [`PaperApplicationService`](../../app/services/applications/paper_application_service.rb), [guardian quick-create](../../app/services/applications/paper_guardian_quick_create_service.rb), [guardian/dependent management](../../app/services/applications/guardian_dependent_management_service.rb) — recheck the reviewed facts before saving and record decisions as `paper_intake` cases. Selecting an existing person reuses that record, which is not a merge. Retired duplicates cannot be selected, and guardian selection also requires an active account.

**Portal dependent creation.** The [dependent controller](../../app/controllers/constituent_portal/dependents_controller.rb) writes dependent, relationship, and any `portal_dependent` case together; see the [guardian relationship guide](guardian_relationship_system.md).

<a id="32-name-and-dob-review-flag"></a>

## Duplicate review

A match is a question, not a verdict. The case holds the evidence and the eventual decision. `users.needs_duplicate_review` is only a cached badge derived from open cases of any source and unresolved current name/date-of-birth pairs — clearing the boolean resolves nothing.

### What blocks application submission

One thing, narrowly: an **open `registration_soft_match` case whose subject is the applicant**. Sign-in, drafting, editing, and autosave stay available throughout.

A guardian's own case does not block their dependent's application. Being named as a candidate on someone else's case blocks nothing. Cases from other sources do not gate at all. And resolving one qualifying case is not enough while another is still open.

[`Application.identity_review_pending_for?`](../../app/models/concerns/application_submission_eligibility.rb) is the rule; [`ApplicationCreator`](../../app/services/applications/application_creator.rb) evaluates it under lock at submission, and the portal calls the same predicate to explain the restriction beforehand.

### Resolutions

The [admin duplicate review controller](../../app/controllers/admin/duplicate_reviews_controller.rb) presents evidence and actions; [`ResolutionService`](../../app/services/duplicate_review_cases/resolution_service.rb) records the decision with its actor and rationale.

| Outcome | Meaning |
| --- | --- |
| `keep_separate` | Different people. Nothing is combined. |
| `existing_person_selected` | Paper intake chose an existing candidate for the proposed identity. |
| `same_person_confirmed` | A merge completed through the merge service. |
| `superseded_by_merge` | A related post-import case became moot because of a merge — not an identity finding of its own. |

Existing-person selection is recorded only by inline paper intake through `ResolutionService#select_existing`, not by the admin queue resolve action.

For a registration case, only keeping the records separate or completing a merge releases the submission gate. Needing more information, a security investigation, and an unverified relationship all leave the case open. Resolved cases keep their decision and evidence.

### Post-import pairs

[`DuplicateReconciliation::Population`](../../app/services/duplicate_reconciliation/population.rb) derives candidate pairs from names and dates of birth, and [`ReviewPairService`](../../app/services/duplicate_reconciliation/review_pair_service.rb) rechecks a pair before opening or reusing a case. The queue may group connected pairs for browsing, but each decision covers exactly two people: keeping A and B separate says nothing about A and C.

[`DuplicateReviewCase.reconciliation_pairs`](../../app/models/duplicate_review_case.rb) recognizes strict post-import cases and terminal inline paper keep-separate cases with one distinct pair and a `name_dob` reason. Existing-person selection, address-only decisions, and historical audit-only records do not settle pairs. Open pair work takes precedence over completed evidence. Discovery and flag projection use the same case-owned rules; a different unresolved pair can still require a flag after one pair is settled.

## Merging

[`Users::DuplicateMergeService`](../../app/services/users/duplicate_merge_service.rb) handles confirmed same-person merges from registration soft matches and valid post-import pairs. Staff pick the survivor, explain the decision, and settle conflicting contact and delivery details. Four boundaries hold:

- **Login stays with the survivor** — its password, MFA, and login email. When only one record is email-backed, that record has to be the survivor.
- **Applications and relationships move with their history**, lifecycle intact.
- **The duplicate is retired, not deleted.** It goes inactive, points at the survivor, loses its primary email, phone, and sessions, and remains as evidence.
- **Live work can block the merge** — conflicting applications, a pending recovery request, incompatible guardian relationships, or secure requests whose delivery ownership would become invalid.

Hand-editing foreign keys or destroying the duplicate skips the eligibility rechecks the service performs under shared locks, and leaves no record of the decision. Writers that participate in merges follow the [merge integrity contract](service_architecture.md#merge-integrity-lock-boundary).

## Guardians

[`UserGuardianship`](../../app/models/concerns/user_guardianship.rb) owns relationship queries and effective-contact helpers. A guardian/dependent pair is unique, and nobody can be their own guardian.

A relationship and an application's `managing_guardian` answer different questions: the relationship says these two people are connected, the application says who manages that application. Recipient selection belongs to each workflow — `application.user.email` is not a general answer. See [Guardian Relationship System](guardian_relationship_system.md), particularly [stored contact ownership](guardian_relationship_system.md#canonical-stored-contact-ownership).

## Admin tools

[`Admin::UsersController`](../../app/controllers/admin/users_controller.rb) covers lists, profile edits, roles, capabilities, and account actions, with search and filtering in [`Users::FilterService`](../../app/services/users/filter_service.rb). Because email is encrypted, email search goes through [HMAC search tokens](../../app/models/concerns/user_email_search.rb); a dependent with no email of their own can also be found by a linked guardian's.

Two destructive-sounding actions differ more than their names suggest. **Delete MFA tokens** removes WebAuthn, TOTP, and SMS credentials plus sessions, and is refused for the system user; approving a [security-key recovery request](../../app/controllers/admin/recovery_requests_controller.rb) removes only WebAuthn credentials. **Delete user** destroys the record and cascades per its associations, including constituent applications — it is blocked for the system user and for self-deletion, and is not the merge workflow.

### Duplicate maintenance tasks

Defined in [`lib/tasks/duplicates.rake`](../../lib/tasks/duplicates.rake):

| Task | Effect |
| --- | --- |
| `duplicates:discovery` | Bounded read-only diagnostic summary; personal details redacted by default. |
| `duplicates:report` | Reads pair state and prints names and IDs — no raw contact values or dates of birth. `CSV_PATH` writes a file. |
| `duplicates:sync_review_flags` | **Writes** the cached review flags from open cases and unresolved pairs. Creates no cases, events, or notifications. |

`DETAILED_PII=true` on discovery exposes personal information and refuses to run without an attached terminal, specifically so it cannot be piped into a log or run detached. The ordinary report still contains names, so its output is sensitive too.

## Tests

- [Contact predicates](../../test/models/user_contact_predicates_test.rb) and [login identifiers](../../test/models/user_login_identifier_test.rb) — contact versus public access.
- [Registration](../../test/controllers/registrations_controller_test.rb) — duplicate outcomes and account creation.
- [Review resolution](../../test/services/duplicate_review_cases/resolution_service_test.rb) and [merge service](../../test/services/users/duplicate_merge_service_test.rb) — decisions and what survives.
- [Admin users](../../test/controllers/admin/users_controller_test.rb) — profile and account actions.
