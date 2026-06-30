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

- handles existing self-applicant, existing dependent, new guardian/dependent, and new self-applicant scenarios
- creates or updates the relevant users
- creates or updates the `Application`
- sets `submission_method` to `paper`
- stamps `fulfillment_type` as `voucher` only when vouchers are enabled; otherwise paper applications remain equipment-fulfillment
- processes income, residency, ID, and disability certification actions
- sends account-creation notifications after a successful create for portal-eligible users only (`portal_access_eligible?`)
- logs `application_created` after create
- performs reconciliation after the transaction commits

## Applicant Matching And Dedup Branches

Paper intake deliberately branches before it writes the application:

| Branch | When it applies | Service behavior |
|--------|-----------------|------------------|
| Existing self applicant | Admin selects an existing adult constituent for their own application. | Requires contact verification, checks waiting-period eligibility, and blocks when `blocking_new_submission` is true. |
| Existing dependent | Admin selects an existing dependent through `dependent_id`. | Reuses the dependent and relationship, verifies contact strategy, checks waiting-period eligibility, and writes the application for the dependent with the managing guardian. |
| New guardian/dependent | Admin enters guardian and dependent details. | Uses `GuardianDependentManagementService` to create or reuse the guardian, create the dependent, apply contact strategies, create the relationship, and return the dependent/guardian pair to `PaperApplicationService`. |
| New self applicant | No existing applicant is selected. | Creates a constituent through `Applications::UserCreationService`. Supports phone-only (`no_email_address`) and address-only (`no_email_address` + `no_phone_number`) adults with NULL stored contacts when appropriate. Portal-eligible users receive temporary account access; address-only users do not. No-phone intake clears stored phone and sets `phone_type` to `email` when a real email remains, or `letter` when both contacts are absent. |

The admin search/decorated candidate payload exposes whether a candidate is blocked by a waiting period or other `blocking_new_submission` reason. The create path must honor those flags instead of relying only on UI hiding.

Contact verification matters for existing adults because paper intake can change a user's reachable email, phone, or mailing address. The service should either verify that the submitted contact details match what is already on file or explicitly apply the chosen contact strategy before sending account-created or proof follow-up notices.

## Account-Created Notices And Temp-Password Handoff

Paper intake routes are `new` and `create` only (`config/routes.rb`). Quick-create temp-password handoff is wired through `PaperApplicationsController#create` and cleared after a successful create.

When vouchers are enabled and the application is voucher scope, `PaperApplicationService` sends `account_created` notices for portal-eligible users created or reused in the same submission. The notice confirms application receipt; it does **not** include temporary passwords or sign-in links.

Temp passwords for inline creation are used to set `force_password_change` portal access before the notice goes out. Quick-create handoff stores the secret in `Rails.cache` with only a per-user token in the admin session (30-minute TTL):

- On create, resolved passwords and pending handoff user ids are passed into the service.
- If the cache entry is missing at submit time, the notice still sends when the user is portal-eligible; a reconciliation note tells the admin to reset the password manually before sharing login access.

Equipment-fulfillment applications skip account-created messaging even when a portal-eligible user is created.

## Provider-Info Follow-Up

When `params[:no_medical_provider_information]` is present during create, the service currently attempts to auto-send a secure provider-info request by calling `Applications::RequestProviderInfo` after the application write succeeds.

If that follow-up fails, the application still persists and the admin gets a reconciliation note telling them to send it manually from the application page.

## Proof Actions

### Income, residency, and ID

Current paper-proof actions are:

- `accept`
- `reject`
- `none`

Accepted proofs go through `ProofAttachmentService`. Rejected proofs go through the explicit rejection path without requiring an attachment.

### Disability certification

Current disability certification actions are:

- `approved`
- `rejected`
- `not_requested`

Disability certification attachments and rejection handling go through `MedicalCertificationAttachmentService`.

If the rejected disability certification has certifying-professional contact information available, the service routes through `Applications::MedicalCertificationReviewer` so provider follow-up behavior stays centralized. Otherwise it directly calls `MedicalCertificationAttachmentService.reject_certification`.

## Contact Strategy Notes

For dependent intake, the controller/service pair currently works with:

- `email_strategy`
- `phone_strategy`
- `address_strategy`

Those strategies are applied by `Applications::GuardianDependentManagementService`. Existing dependent reuse aliases submitted `dependent_email` and `dependent_phone` into the same strategy path so the final effective contact details are consistent with newly created dependents.

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
