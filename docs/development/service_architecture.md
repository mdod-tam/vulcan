# Service Architecture

This document describes the current service-object patterns and the core service entry points in MAT Vulcan.

## 1 · High-Level Flow

```text
Controller or model callback
  -> service object
  -> model writes / Active Storage / external delivery
  -> AuditEventService and/or NotificationService when needed
  -> job, mailer, or audit-log builder for async/display work
```

Most services are plain Ruby objects under `app/services/`. Many inherit from `BaseService`, but some central services use class methods instead, including `ProofAttachmentService`, `MedicalCertificationAttachmentService`, `NotificationService`, `FaxService`, `SmsService`, and `TwilioVerifyService`.

## 2 · BaseService

`BaseService` lives at `app/services/base_service.rb`. Key pieces:

```ruby
class BaseService
  include SecureErrorSanitizer

  attr_reader :errors

  Result = Struct.new(:success, :message, :data) do
    def success?
      success == true
    end

    def failure?
      !success?
    end
  end

  def initialize(*_args)
    @errors = []
  end

  def success(message = nil, data = nil)
    Result.new(success: true, message: message, data: data)
  end

  def failure(message = nil, data = nil)
    Result.new(success: false, message: message, data: data)
  end

  protected

  def add_error(message)
    @errors << message
    false
  end

  def add_error?(message)
    add_error(message)
  end
end
```

Use `success?`, `failure?`, `message`, and `data` when a service returns `BaseService::Result`. Some legacy services still return booleans and expose `errors`; the routed admin paper-intake path uses `Applications::PaperApplicationService#create`.

`BaseService` also provides `log_error(exception, context = nil)`, which logs the context/backtrace and appends the exception message to `errors`.

## 3 · Main Entry Points

| Service | File | Current role | Result shape |
|---------|------|--------------|--------------|
| `AuditEventService` | `app/services/audit_event_service.rb` | Creates `Event` records and suppresses recent duplicates with a 5-second window. | `Event` or `nil` |
| `NotificationService` | `app/services/notification_service.rb` | Creates `Notification` records, resolves mailers, stores delivery-route metadata, and optionally enqueues delivery. | `Notification` or `nil` |
| `ProofAttachmentService` | `app/services/proof_attachment_service.rb` | Attaches income, residency, and ID proofs while preserving the caller's submission-method metadata. | Hash |
| `MedicalCertificationAttachmentService` | `app/services/medical_certification_attachment_service.rb` | Attaches, rejects, or status-updates disability certifications. | Hash |
| `Applications::PaperApplicationService` | `app/services/applications/paper_application_service.rb` | Creates admin-entered paper applications through the `new`/`create` admin intake route. | Boolean plus `errors` / `reconciliation_note` |
| `Applications::GuardianDependentManagementService` | `app/services/applications/guardian_dependent_management_service.rb` | Creates or links guardian/dependent users and applies contact strategies. | `BaseService::Result` on the success path |
| `Applications::MedicalCertificationService` | `app/services/applications/medical_certification_service.rb` | Requests disability certification from a provider. | `BaseService::Result` |
| `Applications::EventService` | `app/services/applications/event_service.rb` | Logs guardian/dependent application submission and update events. | `Event` or `nil` |
| `Applications::EventDeduplicationService` | `app/services/applications/event_deduplication_service.rb` | Deduplicates timeline inputs for display. | Array |

Related docs:

- Paper intake: [`docs/development/paper_application_architecture.md`](paper_application_architecture.md)
- Audit/event tracking: [`docs/features/audit_event_tracking.md`](../features/audit_event_tracking.md)
- Notifications: [`docs/features/notifications.md`](../features/notifications.md)
- Document signing: [`docs/development/docuseal_integration_guide.md`](docuseal_integration_guide.md)

## 4 · Core Flows

### 4.1 · Paper Applications

```text
Admin::PaperApplicationsController
  -> Applications::PaperApplicationService
  -> UserCreationService / GuardianDependentManagementService
  -> Application
  -> ProofAttachmentService / MedicalCertificationAttachmentService
  -> AuditEventService / NotificationService / mailers
```

Routes:

- `GET /admin/paper_applications/new`
- `POST /admin/paper_applications`
- collection helper routes such as `dependent_form`

Current behavior:

- `create` sets `Current.paper_context = true` during service-owned work and resets it in `ensure`; routed admin paper intake is `new`/`create` only.
- Self-applicant, existing self-applicant, existing dependent, and new guardian/dependent scenarios are handled in the service.
- New guardian/dependent creation uses `Applications::GuardianDependentManagementService`; existing dependent relationships are created directly when missing.
- Contact strategies are `email_strategy`, `phone_strategy`, and `address_strategy`.
- Proof actions include `upload_only`, `accept` / `approved`, `reject` / `rejected`, and `not_requested`.
- Income, residency, and ID proof attachments use `ProofAttachmentService`.
- Medical certification attachments and rejections use `MedicalCertificationAttachmentService`, with provider-notification rejection paths delegated through `Applications::MedicalCertificationReviewer` when provider contact is available.
- After a successful paper write, the service calls `Application#reconcile_workflow_state!`; failures are surfaced through `reconciliation_note` without rolling back the already saved application/proofs.

Primary tests:

- `test/controllers/admin/paper_applications_controller_test.rb`
- `test/services/applications/paper_application_service_test.rb`
- `test/system/admin/paper_applications_test.rb`

### 4.2 · Proof Attachments and Reviews

```ruby
result = ProofAttachmentService.attach_proof(
  application: application,
  proof_type: :income,
  blob_or_file: uploaded_file_or_signed_id,
  status: :not_reviewed,
  admin: current_user,
  submission_method: :web,
  metadata: {}
)
```

`ProofAttachmentService.attach_proof`:

- accepts Active Storage blobs, signed blob IDs, and uploaded-file objects
- tracks duration and blob size in a hash result
- sets `Current.proof_attachment_service_context` while attaching to avoid duplicate model-callback events
- creates typed attachment events such as `income_proof_attached`
- sets proof status and `needs_review_since` for `not_reviewed` uploads
- skips constituent-facing attachment notifications while `Current.paper_context` is true

`ProofAttachmentService.reject_proof_without_attachment` is for paper/admin rejection without a file. It creates a `ProofReview`; the generic `proof_rejected` audit event and proof-resubmission delivery are owned by `ProofReview` and `Applications::RequestProofResubmission`, not by `ProofAttachmentService`.

Primary entry points:

- `ConstituentPortal::Proofs::ProofsController#resubmit`
- `Admin::PaperApplicationsController#create`
- `Admin::ScannedProofsController#create`
- `Applications::SubmitProofResubmission#call`

Primary tests:

- `test/services/proof_attachment_service_test.rb`
- `test/services/proof_attachment_service_callback_test.rb`
- `test/services/applications/request_proof_resubmission_test.rb`

### 4.3 · Disability Certification Requests

```ruby
service = Applications::MedicalCertificationService.new(
  application: application,
  actor: current_user
)
result = service.request_certification
```

Route:

- `POST /admin/applications/:id/resend_medical_certification`

Current behavior:

- Requires `application.medical_provider_email`.
- Uses `update_columns` for `medical_certification_*` timestamp/status/count updates and manually writes the related `ApplicationStatusChange` and `Event`. Treat this as current implementation behavior, not a pattern to copy into new services.
- Creates a record-only `medical_certification_requested` notification through `NotificationService` with `deliver: false`.
- Enqueues `MedicalCertificationEmailJob`, which sends the disability certification request email and updates notification delivery metadata on failure.
- Returns `BaseService::Result`.

Primary tests:

- `test/integration/application_lifecycle_flow_test.rb`
- `test/integration/medical_certification_flow_test.rb`
- `test/jobs/medical_certification_email_job_test.rb`

### 4.4 · Notifications

```ruby
NotificationService.create_and_deliver!(
  type: 'medical_certification_not_provided',
  recipient: user,
  actor: admin,
  notifiable: application,
  metadata: {},
  channel: :email
)
```

Current behavior:

- `channel` accepts `:email` and `:letter`; recipient-facing mailers decide the actual route for preference-routed messages.
- `deliver: false` creates the `Notification` record without enqueuing delivery.
- `NOOP_DELIVERY_ACTIONS` are record-only delivery no-ops, including `proof_approved`, `medical_certification_received`, and `medical_certification_approved`.
- Normal proof-rejection delivery is blocked here. Reviewable proof rejections should use `Applications::RequestProofResubmission`; legacy mailer-only paths must pass `metadata: { delivery_path: 'legacy' }`.
- By default, `NotificationService` creates notification records without audit events. When callers pass `audit: true`, it logs notification-created/sent/failed events through `AuditEventService`.

Primary tests:

- `test/services/notification_service_test.rb`
- `test/services/printed_letter_delivery_integration_test.rb`

### 4.5 · Audit Events and Timeline Deduplication

```ruby
AuditEventService.log(
  action: 'proof_approved',
  actor: admin,
  auditable: application,
  metadata: { proof_type: 'income' }
)
```

`AuditEventService` writes `Event` records and suppresses recent duplicates for the same auditable record unless the action is excluded, such as `application_created`.

`Applications::EventDeduplicationService` is display-focused. It groups mixed timeline inputs in 1-minute buckets by fingerprint, then chooses the best representative. Current priority is:

1. `application_created`
2. `ApplicationStatusChange`
3. `ProofReview` or `Event`
4. `Notification`

It handles special fingerprints for disability certification status changes, proof submissions, proof reviews, provider-info requests, proof-resubmission requests, and secure-request revocations.

Primary tests:

- `test/services/applications/event_deduplication_service_test.rb`
- `test/services/applications/audit_log_builder_test.rb`

### 4.6 · Training and Evaluation Services

Training services currently include:

- `TrainingSessions::ScheduleService`
- `TrainingSessions::RescheduleService`
- `TrainingSessions::CompleteService`
- `TrainingSessions::CancelService`
- `TrainingSessions::UpdateStatusService`
- `TrainingSessions::ScheduleFollowUpService`
- `TrainingSessions::AuditLogBuilder`

Evaluation services currently in this checkout include:

- `Evaluations::ScheduleService`
- `Evaluations::RescheduleService`
- `Evaluations::SubmissionService`
- `Evaluations::AuditLogBuilder`

These services use `BaseService::Result`, wrap multi-record changes in transactions, and log lifecycle events through `AuditEventService`. Evaluator routes include member actions for `schedule`, `reschedule`, and `submit_report`.

Primary tests:

- `test/services/training_sessions/*_test.rb`
- `test/services/evaluations/*_test.rb`
- `test/controllers/evaluator/evaluations_controller_test.rb`
- `test/controllers/trainers/training_sessions_controller_test.rb`

## 5 · CurrentAttributes

`Current` lives at `app/models/current.rb`.

| Attribute | Verified use |
|-----------|--------------|
| `paper_context` | Paper intake and paper/scanned attachment validation bypasses. |
| `resubmitting_proof` | Constituent proof resubmission validation context. |
| `skip_proof_validation` | Tests and certification-upload service contexts. |
| `reviewing_single_proof` | `Applications::ProofReviewer` targeted review operations. |
| `proof_attachment_service_context` | Prevents duplicate proof events while `ProofAttachmentService` owns attachment writes. |
| `force_notifications` | Test-only notification behavior. |
| `test_user_id` | Test authentication helpers. |
| `user`, `request_id`, `user_agent`, `ip_address` | Request context and audit metadata. |

Use the predicate helpers (`paper_context?`, `resubmitting_proof?`, etc.) when checking booleans. Reset temporary values with `ensure` in services and `Current.reset` or local helpers in tests.

## 6 · Service Testing Patterns

This repo uses Rails Minitest under `test/`.

Use focused service tests for service-owned behavior and integration/controller tests for entry-point behavior. Prefer real service calls for attachment and workflow integration; stubbing `ProofAttachmentService.attach_proof` in integration tests can produce false positives because the attachment is not actually persisted.

Examples to copy before adding new coverage:

- `test/services/proof_attachment_service_test.rb`
- `test/services/applications/paper_application_service_test.rb`
- `test/services/applications/request_proof_resubmission_test.rb`
- `test/services/notification_service_test.rb`
- `test/services/evaluations/schedule_service_test.rb`
