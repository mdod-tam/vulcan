# Current Application Features

This guide maps MAT Vulcan's current, verified Rails feature paths for application intake, review, notifications, and fulfillment.

---

## 1. Application Lifecycle

Applications start as drafts, are submitted for review, move through proof and disability certification review, and may issue a voucher after approval.

```text
draft
  -> in_progress
  -> awaiting_proof or awaiting_dcf
  -> approved or rejected
  -> archived when retained as history
```

| Status | Verified meaning | Common next step |
| --- | --- | --- |
| `draft` | Constituent or managing guardian is still editing. | Submit application. |
| `in_progress` | Submitted and ready for staff workflow. | Review income, residency, and ID proofs. |
| `awaiting_proof` | Waiting for required constituent proof uploads. | Constituent or secure form recipient submits proof. |
| `reminder_sent` | Reminder state for pending proof follow-up. | Constituent submits missing proof. |
| `awaiting_dcf` | Required proofs are approved and disability certification is pending. | Request or review DCF. |
| `approved` | Application requirements are met. | Issue equipment workflow or voucher. |
| `rejected` | Application was denied. | Constituent may reapply where policy allows. |
| `archived` | Historical record. | No active workflow. |

Auto-approval runs through `Application#reconcile_workflow_state!` when all current requirements are met:

- Residency proof is approved.
- ID proof is approved.
- Income proof is approved when `income_proof_required` is true for the application.
- Disability certification is approved.

Main code paths:

| Path | Role |
| --- | --- |
| `app/controllers/constituent_portal/applications_controller.rb` | Online draft, edit, submit, autosave, and training request entry points. |
| `app/forms/application_form.rb` | Validates portal application form data before persistence. |
| `app/services/applications/application_creator.rb` | Creates or updates application records, attaches initial proofs, and logs creation/update events. |
| `app/models/application.rb` | Owns status enums, proof predicates, guardian access, and voucher eligibility. |
| `app/models/concerns/application_status_management.rb` | Reconciles workflow state, auto-approval, and DCF escalation. |
| `app/controllers/admin/paper_applications_controller.rb` | Admin paper intake entry point. See `docs/development/paper_application_architecture.md`. |

---

## 2. Proof Management

Reviewable proof types are income, residency, and ID. Disability certification has its own workflow in section 3.

| Type | Status enum | Attachment | Reviewable by `ProofReview` |
| --- | --- | --- | --- |
| Income | `income_proof_status` | `income_proof` | Yes, when income proof is required. |
| Residency | `residency_proof_status` | `residency_proof` | Yes. |
| ID | `id_proof_status` | `id_proof` | Yes. |

`ProofAttachmentService` is the shared attachment service for portal proof resubmissions, admin scanned proof upload, paper intake, and secure proof form submissions. It accepts uploaded files, signed blob IDs, or existing blobs; writes attachment audit events unless the caller opts out; updates the proof status column; and returns a hash with `:success`, `:error`, `:duration_ms`, and `:blob_size` when available.

```ruby
ProofAttachmentService.attach_proof({
  application: app,
  proof_type: :income,
  blob_or_file: file,
  status: :approved,
  admin: current_admin,
  submission_method: :paper,
  metadata: { ip_address: request.remote_ip }
})
```

Paper rejection without a file is also routed through the service:

```ruby
ProofAttachmentService.reject_proof_without_attachment(
  application: app,
  proof_type: :income,
  admin: current_admin,
  submission_method: :paper,
  reason: "invalid_document",
  notes: "Document does not meet requirements"
)
```

`ProofReviewService` is the admin-facing review entry point. It delegates to `Applications::ProofReviewer`, which updates the proof status column and creates or updates the canonical `ProofReview` record. Approved income, residency, and ID reviews log `proof_approved` and create record-only approval notifications. Rejections log a generic `proof_rejected` event and use `Applications::RequestProofResubmission` for constituent-facing resubmission delivery.

If a rejection is saved but secure upload request delivery fails, the review remains recorded and admins receive an alert that the review succeeded but the secure upload request was not delivered.

Main code paths:

| Path | Role |
| --- | --- |
| `app/services/proof_attachment_service.rb` | Shared proof attachment and paper no-file rejection orchestration. |
| `app/services/proof_review_service.rb` | Admin proof-review orchestration and delivery-warning result data. |
| `app/services/applications/proof_reviewer.rb` | Admin review workflow for proof approval/rejection. |
| `app/models/proof_review.rb` | Review records, rejection side effects, and approval/rejection audit behavior. |
| `app/controllers/constituent_portal/proofs/proofs_controller.rb` | Constituent proof resubmission and direct upload setup. |
| `app/controllers/admin/scanned_proofs_controller.rb` | Admin scanned income/residency proof upload. |
| `app/controllers/secure_proof_forms_controller.rb` | Tokenized secure proof upload form submission. |

---

## 3. Disability Certification

Disability certification status is separate from reviewable proof status. The code still uses identifiers such as `medical_certification_status`, but user-facing documentation should describe the requirement as disability certification.

```text
not_requested -> requested -> received -> approved
                                \-> rejected
```

| Channel | Current behavior | Main entry point |
| --- | --- | --- |
| Provider request email | Admin requests a DCF by email; the app records a request notification and enqueues mail delivery. | `Applications::MedicalCertificationService`, `MedicalCertificationEmailJob` |
| Secure upload form | Admin sends a tokenized certification upload request; provider submits through a secure public form. | `Applications::RequestCertificationUpload`, `Applications::SubmitCertificationUpload` |
| DocuSeal | Admin sends a DocuSeal request; webhooks update document-signing state and attach completed PDFs as received unless an existing secure-uploaded certification must be preserved. | `DocumentSigning::SubmissionService`, `Webhooks::DocusealController` |
| Manual upload/status review | Admin uploads or updates certification status from the application show page. | `Admin::ApplicationsController`, `MedicalCertificationAttachmentService` |
| Provider rejection notice | Rejections create certification audit/status records and try provider email/fax delivery. | `Applications::MedicalCertificationReviewer`, `MedicalProviderNotifier`, `FaxService` |
| Print DCF | Admin queues a DCF PDF for printing. | `Applications::MedicalCertificationPdfService`, `PrintQueueItem` |

There is no current `MedicalCertificationMailbox`, `ProofSubmissionMailbox`, or `ApplicationMailbox` class in `app/`; inbound email processing is not a live entry point. Proofs and optional provider certification uploads use secure temporary forms.

DocuSeal uses its own status column:

| `document_signing_status` | Meaning |
| --- | --- |
| `not_sent` | No signing request has been sent. |
| `sent` | Request sent to provider. |
| `opened` | Provider opened the signing link. |
| `signed` | Provider completed signing. |
| `declined` | Provider declined signing. |

Important distinction: DocuSeal `signed` means the provider completed the signing flow. The application still needs admin review before `medical_certification_status` becomes `approved`.

---

## 4. Guardian and Dependent Applications

A managing guardian is the adult user responsible for a dependent's application. The relationship is stored in `GuardianRelationship`; the specific application owner is still the dependent constituent.

```ruby
GuardianRelationship.create!(
  guardian_user: guardian,
  dependent_user: dependent,
  relationship_type: "Parent"
)
```

| Helper or scope | Meaning |
| --- | --- |
| `application.for_dependent?` | True when `managing_guardian_id` is present. |
| `application.managing_guardian` | Adult user managing this application. |
| `application.editable_by?(user)` | True for the applicant on self applications, or the managing guardian on dependent applications. |
| `application.guardian_relationship_type` | Relationship type from `GuardianRelationship`. |
| `Application.editable_by(user)` | Applications the user may edit. |
| `Application.accessible_by(user)` | Currently the same strict ownership set as editable applications. |
| `Application.managed_by(guardian)` | Applications whose `managing_guardian_id` is the guardian. |

Portal submissions use `ApplicationForm` to verify that the selected dependent belongs to the current guardian, and `Applications::ApplicationCreator` sets `managing_guardian_id` for dependent applications.

Related doc: `docs/development/guardian_relationship_system.md`.

---

## 5. Voucher System

Voucher assignment is optional and depends on `FeatureFlag.enabled?(:vouchers_enabled)` and `Application#fulfillment_type`.

When an application transitions to `approved` through `Application#transition_status!`, voucher applications enqueue `IssueInitialVoucherJob` after commit. The job calls `Application#maybe_assign_initial_voucher!`, which creates a voucher only when the application is still eligible:

- Application fulfillment type is `voucher`.
- Application status is `approved`.
- Required proofs are approved.
- Disability certification is approved.
- No voucher already exists.

Voucher states are:

```text
active -> redeemed
active -> expired
active -> cancelled
```

Vendor redemption flow:

1. Vendor enters a voucher code under `/vendor_portal/vouchers`.
2. `VoucherVerificationService` verifies the constituent date of birth and stores verification in the session.
3. `Vouchers::RedemptionService` processes redemption.
4. `Voucher#redeem!` creates a `VoucherTransaction`, updates remaining value, and logs `voucher_redeemed`.
5. Invoice generation uses completed, uninvoiced voucher transactions.

Main code paths:

| Path | Role |
| --- | --- |
| `app/models/concerns/voucher_management.rb` | Voucher eligibility and assignment. |
| `app/jobs/issue_initial_voucher_job.rb` | After-commit initial voucher assignment. |
| `app/models/voucher.rb` | Voucher state, redemption, expiration, and audit hooks. |
| `app/models/voucher_transaction.rb` | Redemption transaction records and invoice scopes. |
| `app/controllers/vendor_portal/vouchers_controller.rb` | Vendor verification and redemption UI. |

---

## 6. Training and Evaluation

Training and evaluation records share the `StatusManagement` concern.

| Status | Used by | Meaning |
| --- | --- | --- |
| `requested` | Training, evaluation | Assigned/requested but not scheduled. |
| `scheduled` | Training, evaluation | Date/time set. |
| `confirmed` | Training, evaluation | Confirmed session. |
| `completed` | Training, evaluation | Session or evaluation completed. |
| `cancelled` | Training, evaluation | Cancelled record; considered follow-up state. |
| `rescheduled` | Legacy/display compatibility | Current reschedules usually keep `scheduled` and log a reschedule event. |
| `no_show` | Training, evaluation | Missed session/evaluation; considered follow-up state. |

Training assignment is admin-driven from an approved application. `Application#assign_trainer!` creates a `TrainingSession` in `requested` status after checking the service window, quota, and existing open sessions. Trainers then schedule, reschedule, complete, cancel, or create follow-up sessions through `TrainingSessions::*` services.

Evaluation assignment is also admin-driven from an approved application. `Application#request_evaluation!` marks an application as needing evaluation; `Application#assign_evaluator!` creates an `Evaluation`. Evaluators schedule, reschedule, and submit reports through `Evaluations::ScheduleService`, `Evaluations::RescheduleService`, and `Evaluations::SubmissionService`.

Main code paths:

| Path | Role |
| --- | --- |
| `app/models/training_session.rb` | Training associations, validations, open-session rules, notification callbacks. |
| `app/models/evaluation.rb` | Evaluation associations, validations, report completion rules, notification callbacks. |
| `app/models/concerns/status_management.rb` | Shared training/evaluation status enum and predicates. |
| `app/models/concerns/training_management.rb` | Application-level trainer assignment and quota checks. |
| `app/models/concerns/evaluation_management.rb` | Application-level evaluator assignment. |
| `app/services/training_sessions/` | Training lifecycle services. |
| `app/services/evaluations/` | Evaluation schedule, reschedule, and submission services. |

---

## 7. Notifications and Letters

`NotificationService` creates `Notification` rows and, when delivery is enabled, routes configured actions to mailers. The requested channel is `:email` or `:letter`; recipient-facing mailers can route letter-preference recipients into `PrintQueueItem`.

```ruby
NotificationService.create_and_deliver!(
  type: "proof_approved",
  recipient: user,
  actor: admin,
  notifiable: application,
  metadata: { proof_type: "income" },
  channel: :email,
  deliver: false
)
```

Important distinctions:

- In-app notifications are `Notification` records rendered at `/notifications`; Rails flash messages are request feedback, not persistent in-app notifications.
- `NotificationService` writes audit `Event` rows only when callers pass `audit: true`.
- Reviewable proof rejection delivery uses `Applications::RequestProofResubmission`; bare `NotificationService` calls for those actions are blocked unless marked as legacy delivery.
- Email templates support `legacy_percent` and `liquid` syntax through `EmailTemplates::Renderer`; Liquid templates use exact required/optional variable paths and are gated by `email_template_liquid`.
- `UpdateEmailStatusJob` only polls Postmark for `medical_certification_requested` notifications with a `message_id`.

Main code paths:

| Path | Role |
| --- | --- |
| `app/services/notification_service.rb` | Notification record creation, delivery routing, optional audit events. |
| `app/models/notification.rb` | Notification state, read tracking, email tracking helpers. |
| `app/controllers/notifications_controller.rb` | Notification list, mark-read, and email-status check actions. |
| `app/jobs/update_email_status_job.rb` | Postmark status polling for disability certification request notifications. |
| `app/services/postmark_email_tracker.rb` | Postmark API wrapper. |
| `app/models/print_queue_item.rb` | Letter queue records. |

Related docs: `docs/features/notifications.md` and `docs/infrastructure/email_system.md`.

---

## 8. Audit and Events

Business events are stored as `Event` rows through `AuditEventService.log`.

```ruby
AuditEventService.log(
  action: "proof_approved",
  actor: admin,
  auditable: application,
  metadata: { proof_type: "income" }
)
```

Common event families:

| Family | Example actions |
| --- | --- |
| Application lifecycle | `application_created`, `application_updated`, `application_status_changed`, `application_approved` |
| Proofs | `income_proof_attached`, `id_proof_attached`, `proof_submitted`, `proof_approved`, `proof_rejected` |
| Disability certification | `medical_certification_requested`, `medical_certification_status_changed` |
| DocuSeal | `document_signing_request_sent`, `document_signing_started`, `document_signing_viewed`, `document_signing_completed`, `document_signing_declined`, `document_signing_attachment_failed` |
| Secure requests | `provider_info_requested`, `proof_resubmission_requested`, `cert_upload_requested` |
| Vouchers | `voucher_assigned`, `voucher_redeemed`, `voucher_expired`, `voucher_cancelled` |
| Training/evaluation | `trainer_assigned`, `training_scheduled`, `evaluation_requested`, `evaluation_scheduled`, `evaluation_completed` |

`Applications::EventDeduplicationService` is used by audit-log and timeline builders to keep displays readable by grouping near-duplicate records.

Related doc: `docs/features/audit_event_tracking.md`.

---

## 9. Admin and Portal Entry Points

| Surface | Route | Main use |
| --- | --- | --- |
| Admin applications | `/admin/applications` | Application queues, proof review, disability certification review, assignment, fulfillment, and vouchers when enabled. |
| Admin paper intake | `/admin/paper_applications/new` | Paper application creation. |
| Admin print queue | `/admin/print_queue` | Printable letters and DCF forms. |
| Admin email templates | `/admin/email_templates` | Template review and syncing. |
| Admin users | `/admin/users` | User management and capability assignment. |
| Admin vouchers | `/admin/vouchers` | Voucher management and cancellation. |
| Admin vendors | `/admin/vendors` | Vendor and W-9 management. |
| Pain point analysis | `/admin/application_analytics/pain_points` | Draft drop-off analysis by last visited step. |
| Constituent portal | `/constituent_portal/applications` | Application drafts, submissions, proof uploads, status tracking. |
| Vendor portal | `/vendor_portal/vouchers` | Voucher lookup, DOB verification, redemption. |
| Evaluator portal | `/evaluators/evaluations` | Evaluation scheduling and report submission. |
| Trainer portal | `/trainers/training_sessions` | Training scheduling, completion, cancellation, follow-up. |

---

## 10. Background Jobs

| Job | Purpose |
| --- | --- |
| `MedicalCertificationEmailJob` | Sends disability certification request email. |
| `UpdateEmailStatusJob` | Polls Postmark delivery/open status for disability certification request notifications. |
| `IssueInitialVoucherJob` | Issues the first voucher after an approved transition commits when the application is still eligible. |
| `CheckVoucherExpirationJob` | Processes expired vouchers. |
| `GenerateVendorInvoicesJob` | Creates vendor invoices from completed uninvoiced transactions. |
| `ProofAttachmentMetricsJob` | Monitors proof attachment failures. |
