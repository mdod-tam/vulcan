# Paper Application Architecture (Rails)

This document describes the current admin-only paper application workflow.

## 1 · High-Level Flow

```text
Admin
  -> Admin::PaperApplicationsController
  -> Applications::PaperApplicationService
  -> GuardianDependentManagementService / UserCreationService
  -> Application
  -> ProofAttachmentService / MedicalCertificationAttachmentService
  -> NotificationService / Mailers / AuditEventService
```

Paper intake uses `Current.paper_context = true` during the main service flow so paper-specific validation bypasses remain active while the application and proofs are created.

## 2 · Main Entry Points

### 2.1 Controller

`Admin::PaperApplicationsController` currently:

- normalizes guardian/dependent/application/proof params
- derives `email_strategy`, `phone_strategy`, and `address_strategy`
- calls `Applications::PaperApplicationService` for create and update
- sends a follow-up medical-certification notification in specific rejected/no-provider cases after a successful create

### 2.2 Service

`Applications::PaperApplicationService` currently:

- processes self-applicant, dependent, and existing-dependent scenarios
- creates or reuses guardian/dependent users
- creates the paper `Application`
- sets `submission_method` to `paper`
- determines the initial application status
- processes income, residency, and medical-certification proof actions
- sends account-creation and proof-rejection notifications after successful completion

## 3 · Current.paper_context

The service wraps create/update flows like this:

```ruby
Current.paper_context = true
begin
  # create/update application and process proof actions
ensure
  Current.paper_context = nil
end
```

This is the current mechanism used to bypass proof-related validations during paper processing.

## 4 · Guardian and Dependent Handling

Current dependent intake supports:

- selecting an existing guardian
- creating a new guardian
- selecting an existing dependent for a guardian
- creating a new dependent

Current relationship handling:

- `GuardianRelationship` is created when needed
- `Application#managing_guardian_id` is set for dependent applications

Current contact-strategy handling:

- `email_strategy`
- `phone_strategy`
- `address_strategy`

These strategies are resolved by the controller and applied by `Applications::GuardianDependentManagementService`.

## 5 · Current Proof Processing

### 5.1 Income and residency

Paper proof actions support:

1. `accept` / `approved`
2. `reject` / `rejected`
3. `none`

Current service behavior:

- accepted income/residency proofs use `ProofAttachmentService.attach_proof`
- rejected income/residency proofs use `ProofAttachmentService.reject_proof_without_attachment`
- approval requires a file or signed blob ID

### 5.2 Medical certification

Paper medical-certification actions support:

1. `approved`
2. `rejected`
3. `not_requested`

Current service behavior:

- approval uses `MedicalCertificationAttachmentService.attach_certification`
- rejection uses `MedicalCertificationAttachmentService.reject_certification`
- status-only updates after creation are handled from the admin application show page

## 6 · Initial Status Assignment

`Applications::PaperApplicationService` currently sets the initial application status as follows:

- `awaiting_proof` when medical-provider information is intentionally missing
- `awaiting_proof` when either income or residency proof is rejected or marked as none
- `in_progress` when the paper application includes the expected starting documentation

## 7 · Front-End Pieces

Current paper form controllers include:

- `paper_application_controller`
- `applicant_type_controller`
- `dependent_fields_controller`
- `guardian_picker_controller`
- `document_proof_handler_controller`

The dependent form currently includes checkbox-driven controls for using guardian email, phone, and address.

## 8 · Parameter Shape

The paper service currently works from a normalized parameter hash shaped like:

```ruby
{
  applicant_type: "dependent",
  relationship_type: "Parent",
  guardian_id: 123,
  dependent_id: 456,
  email_strategy: "guardian",
  phone_strategy: "guardian",
  address_strategy: "guardian",
  constituent: { ... },
  application: { ... },
  income_proof_action: "accept",
  residency_proof_action: "reject",
  medical_certification_action: "not_requested"
}
```

Uploads can be sent as direct file params or signed blob IDs.

## 9 · Notifications and Auditing

Current paper-flow notifications include:

- account-creation notifications for newly created users
- proof-rejection notifications for rejected paper proofs
- follow-up medical-certification notifications in specific rejected/no-provider cases

Current paper-flow auditing includes:

- `application_created` or `application_updated`
- proof attachment/rejection audit events from the attachment services
- any `ProofReview` or `ApplicationStatusChange` records created by the downstream services

## 10 · Medical Certification Channels

Current paper-related medical-certification handling includes:

- email request delivery through `Applications::MedicalCertificationService`
- digital signing requests through `DocumentSigning::SubmissionService`
- fax-based provider rejection notices through `MedicalProviderNotifier`
- admin upload/review from the application detail page

Email and inbound fax automation are not yet fully working; consult TODOs for the remaining steps.

## 11 · Testing Notes

Current tests around this flow live primarily in:

- `test/controllers/admin/paper_applications_controller_test.rb`
- `test/services/applications/paper_application_service_test.rb`
- `test/system/admin/paper_applications_test.rb`
- `test/system/admin/paper_application_dependent_guardian_test.rb`

When writing paper-flow tests, keep `Current.paper_context` behavior in mind.
