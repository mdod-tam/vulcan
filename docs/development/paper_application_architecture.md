# Paper Application Architecture

This is the current admin-facing paper application flow.

## Main Entry Points

- Controller: `app/controllers/admin/paper_applications_controller.rb`
- Service: `app/services/applications/paper_application_service.rb`
- Related service: `app/services/applications/guardian_dependent_management_service.rb`
- Related secure-request services:
  - `app/services/applications/request_provider_info.rb`
  - `app/services/applications/request_proof_resubmission.rb`
  - `app/services/applications/request_certification_upload.rb`
- Related proof services:
  - `app/services/proof_attachment_service.rb`
  - `app/services/medical_certification_attachment_service.rb`

## Core Flow

```text
Admin::PaperApplicationsController
  -> normalizes paper-form params
  -> Applications::PaperApplicationService
  -> constituent / guardian / dependent creation or reuse
  -> Application write
  -> proof and disability certification processing
  -> notifications, audit events, and post-write reconciliation
```

## Current.paper_context

`Applications::PaperApplicationService` activates `Current.paper_context` around the paper create/update work and re-enters that context around application/proof writes that need paper-specific validations or callbacks.

That flag matters because downstream proof-review and validation behavior changes when paper intake is in progress. Do not assume after-write notification or reconciliation code still has paper context; the service clears the flag in `ensure` blocks around the write phases.

## Create Result Contract

`PaperApplicationService#create` owns the transaction outcome, and the controller trusts it rather
than inspecting the in-memory record:

| Result | Meaning | Controller response |
|--------|---------|---------------------|
| `true`, no warning | Committed cleanly | Redirect to the application |
| `true`, warning, `commit_confirmed?` | Committed, but a post-commit step failed — reconciliation, a named post-creation step, or a model `after_commit` | Redirect to the real application with the warning alongside the success notice |
| `true`, warning, **not** `commit_confirmed?` | The write could not be verified — the callback raised *and* the confirming query failed | Redirect to the applications **list** with the warning. Never to the record's own page: if the row is not there, "application not found" replaces the guidance |
| `false` | **Nothing committed** (a confirmed rollback) | Re-render the paper form with the original service error |

`false` unambiguously means nothing was written. That is not free: `after_commit` callbacks run as
the transaction block exits, so a raise from one — `ProofReview#handle_post_review_actions` fires on
every rejected proof — escapes *after* the data is durable. The service checks durable existence
before classifying, so a committed application is never reported as a failure. Reporting it as one
would invite the admin to submit again and create a duplicate.

Never infer commit state from `service.application.persisted?`. It is wrong in both directions: false
after a rollback restores the record, true after a commit whose callback then raised.

### What a re-rendered form restores

Everything submitted except the files, on the paths listed below. This is a real contract, not an
aspiration: a field accepted for processing but missing from `build_submitted_params`, or rendered
from the record rather than the submission, is silently dropped on a retry. Both mistakes have
happened here.

Coverage is split deliberately, and [`paper_application_retry_contract.md`](paper_application_retry_contract.md) records which field is
proved where: request tests own value binding and the blank/false/absent distinctions, while the
system matrix in `test/system/admin/paper_application_rollback_test.rb` owns picker behaviour, branch
reveal, and the cases where the browser's own submission rules matter -- an unchecked box is omitted
entirely, and a disabled control is not submitted, neither of which a request test can reproduce.

The existing-dependent branch is covered end to end in that system test -- selecting an on-file
dependent, failing, and retrying to success. Guardian quick-create identity decisions are exercised
through the browser in `test/system/admin/paper_application_dependent_guardian_test.rb`; dependent
preflight, correction, override, and on-file selection are exercised in
`test/system/admin/paper_identity_review_test.rb`. Request tests still own server-rendered retry
bindings. Together those paths cover applicant and application fields, disability selections and
self-certification, attestations, contact strategies, applicant-type branch, guardian/dependent
selection, all four proof dispositions, and their rejection reasons. The four native file inputs
cannot be repopulated by a server render, so staff reselect only the documents their restored
dispositions still require — a rejected proof needs none.

The retry-field allowlist lives in `build_submitted_params`. A field that is accepted for processing
but missing from that list will be silently dropped on a retry.

## What The Controller Owns

`Admin::PaperApplicationsController` currently:

- casts complex boolean params before create and update
- normalizes service params for create and update
- derives `email_strategy`, `phone_strategy`, and `address_strategy`
- supports dependent form and recipient-preference lookup endpoints
- has separate rejection-notification actions for income-threshold workflows

The controller does not own the main paper-application side effects after create; those happen in `Applications::PaperApplicationService`.

## What The Service Owns

`Applications::PaperApplicationService` currently:

- handles existing self-applicant, existing dependent, new dependent with a saved/selected guardian,
  and new self-applicant scenarios
- creates or updates the relevant users
- creates or updates the `Application`
- sets `submission_method` to `paper`
- stamps `fulfillment_type` as `voucher` only when vouchers are enabled; otherwise paper applications remain equipment-fulfillment
- processes income, residency, ID, and disability certification actions
- sends account-creation notifications after a successful create for email-backed portal users only (`email_backed_public_portal_account?` / `real_email?`)
- logs `application_created` after create
- performs reconciliation after the transaction commits

## Applicant Matching And Dedup Branches

Paper intake deliberately branches before it writes the application:

| Branch | When it applies | Service behavior |
|--------|-----------------|------------------|
| Existing self applicant | Admin selects an existing adult constituent for their own application. | Requires contact verification, checks waiting-period eligibility, and blocks when `blocking_new_submission` is true. |
| Existing dependent | Admin selects an existing dependent through `dependent_id`. | Reuses the dependent and relationship, verifies contact strategy, checks waiting-period eligibility, and writes the application for the dependent with the managing guardian. |
| Guardian/dependent | Admin first saves or selects a guardian, then selects an on-file dependent or enters a new dependent. | `PaperGuardianQuickCreateService` owns new-guardian JSON creation. Final submission requires the saved/selected `guardian_id`; `PaperApplicationService` reuses only an eligible dependent already related to that guardian, while `GuardianDependentManagementService` creates one new dependent plus its relationship. Neither path manufactures a relationship to an unrelated existing record from a submitted id. |
| New self applicant | No existing applicant is selected. | Always creates a new constituent through `Applications::UserCreationService` with `skip_user_lookup: true`. Duplicate email or phone fails validation instead of silently attaching an unrelated user. Supports phone-only and address-only adults with NULL stored contacts when appropriate. Email-backed portal users get internal forced-change account setup; phone-only and address-only users do not. No-phone intake sets `phone_type` to `email` when a real email remains, or `letter` when both contacts are absent. |

New paper self and dependent records run through `DuplicateDetectionService` before the application
write. A new guardian runs the same review before its separate JSON quick-create write. Exact email
or phone collisions hard-block new-record creation so paper intake cannot silently attach an
unrelated user.

Soft name+DOB/address matches are handled differently by branch:

- **New self applicant or dependent** — adjudicated inline, not queued. `Applications::PaperIdentityReview` is the single owner of normalized facts, candidate presentation, role-specific selectability, and signed decisions. The form calls the read-only review before native multipart submission; the canonical writer recomputes it under `PaperIdentityCreationLock` inside the application transaction. A dependent decision is additionally bound to the selected guardian, relationship, and contact strategies. A valid different-person override logs exactly one bounded `paper_identity_no_match_confirmed` event; a clear result logs none. Neither branch opens `paper_intake` cases.
- **Guardian** — the visible `Save Guardian` JSON step is the only new-guardian writer. `PaperGuardianQuickCreateService` applies guardian contact flags, recomputes review under the shared identity lock, and returns clear, candidate, exact-contact, selected-existing, or confirmed-override outcomes. Final paper submission requires its returned `guardian_id` (or an existing selection); it never creates from inline `guardian_attributes`. No `admin_create` or `paper_intake` case is opened.

The admin search/decorated candidate payload exposes whether a candidate is blocked by a waiting period or other `blocking_new_submission` reason. The create path must honor those flags instead of relying only on UI hiding.

Contact verification matters for existing adults because paper intake can change a user's reachable email, phone, or mailing address. The service should either verify that the submitted contact details match what is already on file or explicitly apply the chosen contact strategy before sending account-created or proof follow-up notices.

## Account-Created Notices And Quick-Create Markers

Paper intake routes are `new`, `create`, and the read-only `identity_review` collection POST (`config/routes.rb`). The admin form calls `identity_review` before new-self and new-dependent submission; existing-record branches are requalified by the writer instead. The endpoint detects, describes and signs, and never writes. Quick-created **email-backed** portal user markers are wired through `PaperApplicationsController#create` and cleared after a successful create.

When vouchers are enabled and the application is voucher scope, `PaperApplicationService` sends `account_created` notices for email-backed portal users created in the same submission or quick-created in the same browser session. The notice confirms application receipt; it does **not** include temporary passwords or sign-in links.

`Applications::UserCreationService` sets an internal initial password and `force_password_change` for email-backed portal users, but does not return the raw password. Quick-create markers store only email-backed portal user ids plus timestamps in the admin session (30-minute TTL):

- On create, quick-created email-backed portal user ids are passed into the service.
- For marked users, the admin warning reminds staff that no temporary password is retained and account help should use the existing account access link flow.

Equipment-fulfillment applications skip account-created messaging even when an email-backed portal user is created.

## Provider-Info Follow-Up

When `params[:no_medical_provider_information]` is present during create, the service currently attempts to auto-send a secure provider-info request by calling `Applications::RequestProviderInfo` after the application write succeeds.

If that follow-up fails, the application still persists. The request runs as an isolated post-creation step, so its failure does not cancel the steps around it, and the admin gets a warning naming the step -- "the certifying provider request did not finish" -- rather than a generic reconciliation note. The same failure is written to the audit trail as an `application_post_creation_step_failed` event carrying the step name, so it is still visible after the flash is gone.

## Proof Actions

### Income, residency, and ID

Current paper-proof actions, as posted by the form in `<proof>_proof_action`, are:

- `upload_only` — attach now, review later
- `accept` — attach and approve
- `reject` — no attachment; requires `<proof>_proof_rejection_reason`, and `<proof>_proof_custom_rejection_reason` when that reason is `other`

"None Provided" is not a fourth action: it is `reject` with the reason `none_provided`.

Accepted and upload-only proofs go through `ProofAttachmentService`. Rejected proofs go through the
explicit rejection path without requiring an attachment, and record a `ProofReview` carrying the
resolved reason text and its `rejection_reason_code`.

### Disability certification

Current disability certification actions, posted in `medical_certification_action`, are:

- `upload_only`
- `approved` — the default on a *fresh* form only; a re-rendered retry never defaults it
- `rejected` — requires `medical_certification_rejection_reason`, plus
  `medical_certification_custom_rejection_reason` when that reason is `other`

`not_requested` is not one of them.

Disability certification attachments and rejection handling go through `MedicalCertificationAttachmentService`.

If the rejected disability certification has certifying-professional contact information available, the service routes through `Applications::MedicalCertificationReviewer` so provider follow-up behavior stays centralized. Otherwise it directly calls `MedicalCertificationAttachmentService.reject_certification`.

## Contact Strategy Notes

For dependent intake, the controller/service pair currently works with:

- `email_strategy`
- `phone_strategy`
- `address_strategy`

Those strategies are applied by `Applications::GuardianDependentManagementService`. Existing dependent reuse runs the same strategy application through `PaperApplicationService#apply_dependent_contact_strategies!` before persisting contact updates so guardian/no-contact choices overwrite stale direct contact data.

## Fulfillment Notes

Paper application create stamps fulfillment from the current feature state:

- `voucher` when `FeatureFlag.enabled?(:vouchers_enabled)` is true and the paper path is creating a voucher-fulfillment application
- `equipment` when voucher fulfillment is disabled or not selected

Voucher-only account-created messaging should not be sent for equipment-fulfillment applications. Approval reconciliation can approve either fulfillment type, but only voucher applications enqueue voucher issuance.

## Good Starting Tests

- `test/controllers/admin/paper_applications_controller_test.rb`
- `test/services/applications/paper_application_service_test.rb`
- `test/services/applications/dependent_email_handling_test.rb`
- `test/system/admin/paper_applications_test.rb`
- `test/system/admin/paper_application_dependent_guardian_test.rb`
- Add focused cases for existing self applicants, existing dependents, waiting-period blocking, `blocking_new_submission`, contact verification, contact strategies, and fulfillment stamping.

## Notes For Agents

- Start with the exact controller action and service path the bug or change uses.
- Keep `Current.paper_context` in mind before assuming proof-review callbacks behave like the portal flow.
- Do not add parallel audit or notification paths when the service or downstream proof services already own them.
