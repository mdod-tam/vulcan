# Audit And Event Tracking System

This guide explains how MAT Vulcan records business events, displays application history, and avoids duplicate audit noise.

It is meant to describe behavior and ownership. For exact implementation details, follow the code paths listed near the end.

---

## 1. What Audit Events Are For

Audit events answer "what happened?"

Use audit events for:

- application lifecycle changes
- proof uploads and proof review outcomes
- disability certification requests and review outcomes
- secure request creation, submission, expiration, and revocation
- voucher, training, evaluation, vendor, account, and admin actions
- compliance and debugging history

Do not use audit events as user communications. Notifications handle communication records and email/letter delivery.

Some workflows create both an audit event and a notification. They should still have separate owners and separate purposes.

---

## 2. System Shape

| Area | Current owner |
| --- | --- |
| Canonical event creation | `AuditEventService` |
| Event storage | `Event` |
| Application status transition history | `ApplicationStatusChange` |
| Proof review history | `ProofReview` |
| Notification history in timelines | `Notification` |
| Admin application history display | `Applications::AuditLogBuilder` |
| Timeline display deduplication | `Applications::EventDeduplicationService` |

`AuditEventService.log` is the normal way to create an `Event` row. It stores the action, actor, optional auditable record, metadata, and request context.

Application history screens do not show only `Event` rows. They combine events, status changes, proof reviews, and selected notifications into one readable timeline.

---

## 3. Audit Vs Notification

| System | Purpose | Examples |
| --- | --- | --- |
| Audit events | Permanent record of system/user actions. | `proof_approved`, `proof_rejected`, `application_status_changed` |
| Notifications | Communication or persistent communication history. | `proof_approved` record-only notification, `proof_resubmission_requested` tracking notification |

Key examples:

- Proof approval logs `proof_approved` and creates a record-only `proof_approved` notification.
- Proof rejection logs `proof_rejected` and then uses secure proof resubmission services for delivery/tracking.
- Application approval is represented by `application_status_changed` with metadata. The current code does not emit `application_auto_approved`.

---

## 4. Creation Deduplication

`AuditEventService` suppresses recent duplicate event creation for the same auditable record. The creation window is 5 seconds.

Current creation deduplication:

- does not run when there is no auditable record
- never suppresses `application_created` or explicit duplicate-review workflow transitions (`duplicate_review_case_resolved`, awaiting-information, security-review, and return-to-review events)
- uses action plus selected metadata for proof submissions, proof attachments, profile updates, feature flag toggles, and secure-request revocation/expiration events
- returns `nil` when a duplicate is suppressed
- raises validation errors when an event cannot be saved

This layer protects the database from obvious duplicate writes. It is separate from display deduplication.

---

## 5. Display Deduplication

`Applications::EventDeduplicationService` keeps timelines readable after different sources report the same logical action.

It groups timeline items in 1-minute buckets by fingerprint and picks the best representative. Current priority is:

1. `application_created`
2. `ApplicationStatusChange`
3. `ProofReview` or `Event`
4. `Notification`

This is display behavior only. It does not delete records and should not be used as a substitute for choosing one event owner.

---

## 6. Main Event Families

| Family | Common actions or records | Notes |
| --- | --- | --- |
| Application lifecycle | `application_created`, `application_updated`, `application_status_changed` | Status changes should go through `Application#transition_status!`. |
| Proof attachment | `<proof_type>_proof_attached`, `<proof_type>_proof_submitted`, `<proof_type>_proof_attachment_failed`, `proof_submitted` | Attachment services and intake flows own these. |
| Proof review | `proof_approved`, `proof_rejected` | `ProofReview` owns approval/rejection audit events. |
| Proof secure requests | `proof_resubmission_requested`, `proof_submitted_via_secure_form`, request revoked/expired events | Secure request services own these. |
| Disability certification | `medical_certification_requested`, `medical_certification_received`, approved/rejected/status events, secure upload and DocuSeal events | Code names still use `medical_certification_*`; user-facing prose should say disability certification. |
| Duplicate review | `duplicate_review_case_opened`, `duplicate_review_case_awaiting_information`, `duplicate_review_case_security_review_started`, `duplicate_review_case_returned_to_review`, `duplicate_review_case_resolved`, `duplicate_user_merged`, `duplicate_review_flag_cleared` | `DuplicateReviewCases::CreateService` owns case-opened rows; `ResolutionService` owns terminal keep-separate/relationship outcomes and nonterminal awaiting/security outcomes; `ResumeService` owns return-to-review; `Users::DuplicateMergeService` emits exactly one merge event; the controller logs legacy-flag clears. |
| Notifications | `notification_<action>_created`, `notification_<action>_sent`, `notification_<action>_failed` when notification auditing is enabled | Domain workflows usually leave `audit: false`. |
| Email provider webhooks | `email_bounced` for matched provider outbound emails | Spam complaints update notification delivery state without a separate audit event today. |
| Vouchers | `voucher_assigned`, `voucher_redeemed`, `voucher_expired`, `voucher_cancelled` | Voucher model and services own these. |
| Training/evaluation | assignment, schedule, reschedule, completion, cancellation, no-show events | Lifecycle services own these. |
| Admin/account changes | user changes, feature flag toggles, notes, security events | Owning controller/service/model logs the event. |

Treat event action names as API. Before adding a new one, search for existing events and displays that already cover the same logical action.

Duplicate-review case audit actor selection is flow-specific: public registration uses `PublicAuditActor` and rolls back account creation if no system actor can open the required case; portal dependent creation uses the signed-in guardian; admin quick-create and paper intake use the current admin/operator.

Every admin workflow transition stores `duplicate_review_case_id`, the resulting state, rationale, and stable outcome context without raw contact values or credentials. Awaiting-information and security-review are pending states, not resolutions; their dedicated events record the transition while the case keeps `needs_duplicate_review`. Security-review entry does not itself suspend/deactivate an account or expire sessions. Account restrictions require a separate authorized action and audit event.

Duplicate-review transitions bypass the five-second creation-deduplication window because each successful service call changes durable state and every rapid await/resume cycle must remain in history. The state change, subject-flag recomputation, and event creation share the service transaction, so an event failure rolls the workflow transition back.

---

## 7. Proof Review Audit Rules

Reviewable proof types are income, residency, and ID.

Current proof review audit behavior:

- `ProofAttachmentService` owns typed attachment/submission events unless the caller opts out.
- Portal, scanned, and paper flows can also write generic `proof_submitted` history for application-level displays.
- `ProofReview` owns `proof_approved` and `proof_rejected`.
- The canonical proof-rejection event is generic `proof_rejected` with proof-type metadata.
- Legacy typed notification actions like `income_proof_rejected` are not canonical audit events.
- Secure proof resubmission request creation, submission, expiration, and revocation are tracked by secure-request services.

If rejected proof request delivery fails, the review remains recorded. The secure request service can revoke active forms and return failure data so the admin workflow can alert staff.

---

## 8. Disability Certification Audit Rules

Disability certification is not just another income/residency/ID proof type.

Current certification-related audit behavior covers:

- provider request email
- tokenized provider upload request
- tokenized provider upload submission
- DocuSeal request and webhook outcomes
- manual/admin upload or status review
- provider rejection follow-up
- printable DCF request paths

Certification request metadata commonly includes the delivery channel, such as email, secure form, mail, or document signing. This lets admin history show how the request was made.

Keep certification audit behavior in certification-specific services unless the product intentionally merges it with the regular proof-review flow.

---

## 9. Context And Metadata

Events capture request context from `Current`, including user agent and IP address when available.

Metadata should be useful, small, and stable. Prefer keys that help staff understand the event and help developers debug it later.

Good metadata usually answers:

- what proof or requirement changed
- which channel or submission method was used
- which secure request or batch was involved
- what status changed from and to
- whether a background delivery failed and why

Avoid storing sensitive data unless there is a specific operational reason and retention is acceptable.

`Current` flags such as `paper_context`, `resubmitting_proof`, `reviewing_single_proof`, and `proof_attachment_service_context` are used to keep callbacks and side effects consistent in specific flows. They should be scoped and reset with `ensure`.

---

## 10. Timeline Display

Application audit timelines are assembled by `Applications::AuditLogBuilder`.

The builder combines:

- direct `Event` rows
- `ApplicationStatusChange` rows
- `ProofReview` rows
- selected `Notification` rows
- profile or related records when relevant

The display layer can include synthetic or transformed entries. That is why a timeline item may not map one-to-one to a single `Event` row.

When troubleshooting a missing timeline item, check both the source record and the builder/deduplication rules.

---

## 11. Querying And Reporting

For support and reporting, start with the normal Rails models:

- `Event` for direct audit rows
- `ApplicationStatusChange` for status history
- `ProofReview` for proof review outcomes
- `Notification` for communication history and selected timeline entries

Prefer scoped, indexed queries by auditable record, action, user, created time, or specific metadata keys. For large exports or reporting jobs, batch records instead of loading entire histories into memory.

The current schema already includes indexes for common event lookups, including auditable records, action plus auditable, user, and JSONB metadata. Add indexes only after confirming a real query is hot.

---

## 12. Testing Guidance

Use focused tests for the event owner:

- service tests for service-owned audit events
- model tests for callback-owned events
- controller/integration tests for full workflow history
- audit log builder tests for timeline aggregation and display deduplication

Prefer behavior assertions:

- the expected action exists for the auditable record
- metadata includes the fields needed by the UI or support workflow
- duplicate creation is suppressed only when it should be
- display deduplication picks the most useful representative
- direct column writes do not silently bypass required audit behavior

Use real workflow paths when possible. Tests that bypass callbacks with `update_column`, `update_columns`, or `save(validate: false)` can hide missing audit records unless the bypass is the subject of the test.

---

## 13. Troubleshooting

### Expected event is missing

Check that the workflow used the owning service or model method, that `AuditEventService.log` was actually reached, and that the event was not suppressed by the 5-second creation deduplication window.

### Timeline is missing an item

Check the underlying source records first. Then check `Applications::AuditLogBuilder` and `Applications::EventDeduplicationService`, because the timeline combines and deduplicates multiple record types.

### Duplicate events appear

Look for multiple owners creating the same logical event, such as a service and a callback both logging the same action. Fix ownership instead of relying on deduplication to hide the issue.

### Event metadata is not useful

Update the event owner to include stable operational metadata. Avoid ad hoc keys that only one view or one test understands.

---

## 14. Change Rules

When changing audit behavior:

- Use `AuditEventService.log` for normal audit row creation.
- Keep one logical event in one owner.
- Do not manually recreate events after bypassing callbacks.
- Use `Application#transition_status!` for application status changes.
- Use proof services and `ProofReview` for proof events.
- Use certification-specific services for disability certification events.
- Keep notification auditing separate from domain audit events.
- Keep metadata stable enough for support, reporting, and UI display.
- Add or update tests where the event is owned, not only where it is displayed.

---

## 15. Where To Look

| Need | Start here |
| --- | --- |
| Create direct audit events | `app/services/audit_event_service.rb` |
| Event model behavior | `app/models/event.rb` |
| Application status changes | `app/models/concerns/application_status_management.rb`, `app/models/application_status_change.rb` |
| Proof review events | `app/models/proof_review.rb`, `app/services/proof_review_service.rb` |
| Proof attachment events | `app/services/proof_attachment_service.rb` |
| Secure request events | `app/models/concerns/secure_tokenizable.rb`, `app/services/secure_form_expiration_recorder.rb` |
| Application audit timeline | `app/services/applications/audit_log_builder.rb` |
| Timeline deduplication | `app/services/applications/event_deduplication_service.rb` |
| Notification delivery/history | `docs/features/notifications.md` |

Related docs:

- [Notification System](notifications.md)
- [Proof Review Process Guide](proof_review_process_guide.md)
- [Application Workflow Guide](application_workflow_guide.md)
- [Service Architecture](../development/service_architecture.md)
