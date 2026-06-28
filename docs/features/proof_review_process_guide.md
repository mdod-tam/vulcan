# Proof Review Process Guide

This guide describes how MAT Vulcan handles proof uploads, admin review, proof rejection, secure resubmission, and application workflow reconciliation.

It is intended as an operational and product-technical reference. For implementation details, start from the services and controllers named in this guide, then follow the current code.

---

## 1. Scope

The normal proof-review flow covers these proof types:

| Proof type | Application status field | Notes |
| --- | --- | --- |
| Income | `income_proof_status` | Required only when the application requires income proof. |
| Residency | `residency_proof_status` | Required for normal eligibility review. |
| ID | `id_proof_status` | Required for normal eligibility review. |

Disability certification is related to eligibility, but it is not part of the normal income/residency/ID proof-review flow. It has its own provider request, secure upload, DocuSeal, manual upload, and review behavior.

There is no Action Mailbox intake path in this checkout. Proof and certification documents arrive through portal forms, admin forms, scanned/paper intake, or tokenized secure public forms.

---

## 2. Ownership Model

Use the existing service boundaries when changing proof behavior:

| Area | Current owner |
| --- | --- |
| Attaching income/residency/ID proof files | `ProofAttachmentService` |
| Admin approval/rejection of income/residency/ID proofs | `ProofReviewService` and the proof reviewer service it delegates to |
| Persistent review history | `ProofReview` records |
| Secure upload requests after rejection | `Applications::RequestProofResubmission` |
| Secure upload form submission | `Applications::SubmitProofResubmission` |
| Application lifecycle reconciliation | `Application#reconcile_workflow_state!` and `Application#transition_status!` |
| Disability certification | Medical certification services, DocuSeal integration, and certification-specific reviewers |

The important rule is that proof state changes should go through these owners. Avoid writing proof status columns directly from controllers, views, jobs, or one-off scripts unless the task is explicitly about repairing data.

---

## 3. High-Level Flow

The proof lifecycle is:

1. A constituent, admin, scanned-paper workflow, or secure request form submits a proof document.
2. MAT Vulcan attaches the document and records that the proof is awaiting review, approved, or rejected depending on the intake path.
3. An admin reviews pending proofs from the admin application tools.
4. Approval updates the proof status, records review history, logs an audit event, and asks the application workflow to reconcile itself.
5. Rejection updates the proof status, records review history, logs an audit event, removes the rejected attachment, and requests proof resubmission through the secure request flow.
6. When all required proofs and disability certification are approved, the application can transition to approved. If proofs are complete but disability certification is still pending, the workflow can escalate to the DCF/certification step.

Proof review does not manually force an application into a final state. It records the proof outcome and then lets workflow reconciliation decide what the broader application status should be.

---

## 4. Submission Paths

### Constituent Portal

Constituents can resubmit rejected income, residency, or ID proofs from the portal. The portal verifies that the application belongs to the constituent or a dependent, confirms the selected proof is reviewable, and allows resubmission only when that proof is currently rejected.

The upload produces proof-submission audit history and returns the proof to staff review.

### Secure Proof Form

Rejected proofs can generate a tokenized secure request form. The request may be delivered by email, SMS, or letter depending on available contact information and staff action.

The secure form is tied to one application and one rejected proof type. When the user submits it successfully, the form is marked submitted and the uploaded proof returns to the normal review queue.

If delivery fails, the review remains saved. Active request forms are revoked, and admin-facing response data indicates that staff still need to follow up.

### Admin Scanned/Paper Intake

Admin scanned proof upload currently supports income and residency proof. Scanned intake can attach and approve a document in one action when staff are recording a paper proof that has already been inspected.

Paper application processing also uses the shared attachment/rejection paths, but it runs in paper context so user-facing side effects are controlled appropriately.

### Disability Certification Intake

Disability certification has separate intake paths:

- provider email request
- tokenized provider upload
- DocuSeal signing
- admin/manual upload
- certification rejection and provider follow-up

Do not treat disability certification as just another reviewable proof type when changing the income/residency/ID review process.

---

## 5. Admin Review Outcomes

### Approval

Approving a proof:

- creates or updates review history
- updates the proof status to approved
- records a `proof_approved` audit event
- creates a record-only approval notification for history
- runs application workflow reconciliation

Approval email/letter delivery for individual proofs is intentionally suppressed today. Constituents can see proof status in the portal, and staff can see the audit and notification history.

### Rejection

Rejecting a proof:

- creates or updates review history
- updates the proof status to rejected
- records a `proof_rejected` audit event
- stores the rejection reason and reason code when present
- removes the rejected attachment
- starts the secure proof-resubmission request process

The canonical rejection audit event is the generic `proof_rejected` event with proof-type metadata. Older typed notification action names such as `income_proof_rejected`, `residency_proof_rejected`, and `id_proof_rejected` still exist in legacy notification code, but they are not the canonical proof-review event.

### Repeated Rejections

Proof rejections count toward the application's rejection thresholds. The current behavior warns near the maximum rejection threshold and archives the application after the maximum is exceeded. Archival goes through the normal application status transition path so status-change records and audit history remain consistent.

---

## 6. Workflow Reconciliation

Proof approval can change the broader application state, but only through the application workflow helpers.

Current eligibility requirements are:

| Requirement | Current behavior |
| --- | --- |
| Residency proof | Must be approved. |
| ID proof | Must be approved. |
| Income proof | Must be approved only when income proof is required for the application. |
| Disability certification | Must be approved before final application approval. |

When proof review asks the application to reconcile itself:

- final states such as approved, rejected, and archived are not reopened
- the application can become approved when all requirements are met
- the application can escalate to DCF/certification when required proofs are complete but disability certification is still pending
- approved voucher-fulfillment applications enqueue initial voucher issuance through the normal status-transition path

Auto-approval is currently represented as an application status change with metadata. The current code does not emit a separate `application_auto_approved` audit event.

---

## 7. Audit And Notifications

Proof-related audit history is split by purpose:

| Purpose | Current event pattern |
| --- | --- |
| File attached or submitted | typed attachment/submission events from the attachment path, plus generic `proof_submitted` in portal/paper/admin flows |
| Secure proof form submitted | `proof_submitted_via_secure_form` |
| Proof approved | `proof_approved` |
| Proof rejected | `proof_rejected` |
| Secure request created/revoked/expired | secure-request events and tracking notifications |
| Application status changed | `application_status_changed` |

Notification records are used both for delivery and for staff/user history. Some proof-review records are intentionally record-only and are not delivered.

When adding or changing a proof side effect, first check whether the attachment service, proof review record, secure request service, or application workflow already emits the event. One logical proof event should have one owner.

---

## 8. Background Work

The current proof-related background jobs support:

- reminding admins about stale proof reviews
- checking proof status and attachment consistency
- tracking attachment success/failure metrics
- cleaning up proof attachments from old archived applications

Certification request delivery uses certification-specific jobs and should not be mixed into income/residency/ID proof delivery without a deliberate design change.

---

## 9. Admin And Frontend Surfaces

Staff review and manage proof state from the admin application tools, including the application show page, proof review routes, and scanned proof intake.

Constituents interact with proof resubmission through the portal or through secure tokenized upload forms. Secure links should be treated as bearer tokens and should not be serialized into background job arguments.

Frontend controllers support upload/rejection form behavior, but business rules should remain in models and services. Views and JavaScript should not decide whether a proof type is reviewable, whether an attachment is required, or whether a rejection should trigger follow-up.

---

## 10. Testing Guidance

Prefer tests that exercise the real workflow owners:

- attachment service tests for proof upload and status changes
- proof review service tests for approval/rejection behavior
- secure proof request and submission tests for rejected proof follow-up
- admin controller tests for Turbo and redirect behavior
- workflow tests for application status reconciliation

Avoid stubbing the proof attachment service in tests that need to prove a real document was persisted. A stubbed success result can hide failures where no Active Storage attachment exists.

Avoid bypassing callbacks with direct column writes in workflow tests unless the test is explicitly about bypass behavior. Use the service paths so audit events, notifications, and reconciliation run as they do in production.

---

## 11. Troubleshooting

### Application status does not match proof statuses

Use workflow reconciliation rather than manually writing the application status. Confirm that income proof is actually required before treating a non-approved income proof as blocking.

### Rejected review saved but no upload request reached the user

Check the review result, active secure request forms, revoked request metadata, and delivery logs. A saved rejection can be valid even when request delivery failed; staff may need to follow up by another channel.

### Missing proof-submission audit history

Check which submission path was used. Some paths write typed attachment events, while portal, scanned, and paper flows also write generic `proof_submitted` history for application-level displays.

### Secure upload link fails

Check that the token resolves to an active secure request form, the request kind matches the proof type, the request has not expired or been revoked, and the upload passes file validation.

---

## 12. Change Rules

When changing proof review:

- Keep proof attachment behavior in the shared attachment path.
- Keep proof approval/rejection history in proof review records.
- Keep secure rejected-proof follow-up in the secure resubmission request path.
- Use workflow reconciliation for application lifecycle changes.
- Use normal status updates that run validations and callbacks.
- Do not add duplicate audit events or notification records for the same logical proof action.
- Treat disability certification as a separate workflow unless the product intentionally redesigns it.

Related docs:

- [Notifications](notifications.md)
- [Audit Event Tracking](audit_event_tracking.md)
- [Application Workflow Guide](application_workflow_guide.md)
- [Service Architecture](../development/service_architecture.md)
- [Current Application Features](../current_application_features.md)
