# Audit and Event Tracking

Audit history answers which actor did what, to which record, and when.

An audit event should clearly describe the business action even when no message is sent.

Notifications record communication.

## How history is built

| Responsibility | Owner |
| --- | --- |
| Write a business event | [AuditEventService.log](../../app/services/audit_event_service.rb) |
| Store action, actor, related record, metadata, and request context | [Event](../../app/models/event.rb) |
| Record application status transitions | [Application#transition_status!](../../app/models/application.rb), with `ApplicationStatusChange` history |
| Record proof review outcomes | [ProofReview](../../app/models/proof_review.rb) |
| Assemble application history | [Applications::AuditLogBuilder](../../app/services/applications/audit_log_builder.rb) |
| Combine repeated timeline entries | [Applications::EventDeduplicationService](../../app/services/applications/event_deduplication_service.rb) |

The application timeline combines events, status changes, proof reviews, selected notifications, and related profile changes. It can also synthesize a creation entry for older applications without a stored creation event. So a timeline entry doesn't guarantee that a matching `Event` row exists.

## Two different kinds of deduplication

**At creation:** `AuditEventService` checks the previous five seconds for the same action, auditable record, and action-specific fingerprint. It returns `nil` when suppressing a duplicate and raises if the new event fails validation. It skips this check for `application_created`, events without an auditable record, and profile/contact/vendor/voucher mutations without an operation ID. Equal masked values cannot identify the same mutation; each real save must remain visible, including a repeated transition.

**At display:** the timeline groups matching fingerprints into one-minute buckets and chooses a representative. It favors creation events, then status changes, then proof reviews/events, then notifications. This changes the display without deleting stored records.

Each business event still needs a single owner. Neither layer substitutes for that: creation-time deduplication is a five-second window, not a concurrency guarantee, and display deduplication only hides what two writers already stored.

Fingerprints are what separate a legitimate repeated action from a duplicate — the blob for an attachment, the case ID for duplicate review, the retired user ID for a merge, the step name for a paper follow-up failure. A caller that passes `operation_id` in metadata distinguishes separate operations even when they occur close together; a retry of the same operation within five seconds is suppressed. Email template edits and toggles use this. The creation and display fingerprints are computed separately, so a new action can be distinguished in one layer and collapsed in the other.

## Event ownership

| Workflow | Where its history belongs |
| --- | --- |
| Application lifecycle | Creation services log creation; `transition_status!` records real status changes as `application_status_changed`. Automatic approval uses that action with trigger metadata. |
| Proof intake and review | Attachment services own upload history; `ProofReview` owns `proof_approved` and `proof_rejected`. Rejection delivery belongs to secure-request services. |
| Disability certification | Certification and document-signing services own provider requests, received documents, review, and signing outcomes. |
| Duplicate review and merging | [CreateService](../../app/services/duplicate_review_cases/create_service.rb), [ResolutionService](../../app/services/duplicate_review_cases/resolution_service.rb), and [DuplicateMergeService](../../app/services/users/duplicate_merge_service.rb) own their respective case/merge events. |
| Paper identity decisions | Case services record `duplicate_review_case_opened` and `duplicate_review_case_resolved` for self-applicant, guardian, and dependent decisions, in the business transaction. Keep-separate records one case per actual pair; existing-person selection creates no second user. See [paper intake](../development/paper_application_architecture.md). |
| Paper follow-up failure | `PaperApplicationService` attempts an `application_post_creation_step_failed` event after a confirmed commit, identifying the failed step and error class. Failure to record this warning must not invite duplicate intake. |
| Communication | `NotificationService` audits notification creation/delivery only when `audit: true`; most callers leave the domain event with its workflow owner. |
| Delivery controls | [ControlWriter](../../app/services/email_delivery/control_writer.rb) owns `email_control_changed` and `email_template_pair_toggled`. Bulk template changes include each pair event and one `email_templates_bulk_enabled` or `email_templates_bulk_disabled` summary in the same transaction. Operation IDs prevent a replay from reversing a later change. |
| Delivery refusals and enqueue failures | [EmailDelivery::Outcome](../../app/services/email_delivery/outcome.rb) owns `email_delivery_suppressed`, `email_delivery_configuration_error`, and `email_delivery_enqueue_failed`, keyed by the original delivery request. The job records adapter failures at the actual enqueue boundary, including after commit. They don't say the provider delivered anything. |
| Staff access and assignment | [CapabilityWriter](../../app/services/users/capability_writer.rb) records `capability_granted` and `capability_removed` on the affected user, one event per capability with a shared operation correlation, and `staff_capability_operation_applied` as the replay receipt. Each affected application gets `trainer_access_removed` or `evaluator_access_removed`; the assignment stays with its former holder. [TrainingManagement](../../app/models/concerns/training_management.rb) and [EvaluationManagement](../../app/models/concerns/evaluation_management.rb) own `trainer_assigned`, `trainer_reassigned`, `trainer_unassigned`, `evaluator_assigned` and `evaluator_reassigned`; every assignment and reassignment event carries the `operation_id` that its notices name. |
| Contact changes | [ContactChangeAudit](../../app/models/concerns/contact_change_audit.rb) records `alternate_contact_updated`, and `medical_provider_info_updated` for a submitted application, from every write path. These events store masked old and new values so staff can see what was replaced without copying full personal values. A secure provider information submission that replaces a value on file sets `review_required`. |
| Vendor W9 | A change to a W-9 field (business name, tax ID, or address) while the W9 is approved or under review records `w9_details_changed` with field names only. Only a newly attached W9 moves the status to pending review. |
| Secure request links | Revocation and expiration events come from each form model's audit hooks; see [secure request links](secure_request_links.md). |

[SecureRequestDelivery](../../app/services/secure_request_delivery.rb) pairs late-suppression notification updates with link revocation in one transaction. The issuing service still owns recipient selection, cooldown rules and any application-state compensation. Invoice/evaluation workflow events retain domain attribution and errors before enqueue; they are distinct from the shared transport outcome. Voucher warnings record `expiration_warning_requested` with the request ID and enqueue outcome; historical `expiration_warning_sent` rows remain part of warning deduplication.

`paper_identity_no_match_confirmed` remains readable as historical evidence and has no new writer. Historical audit-only rows are not automatically treated as pair decisions.

Action names are an interface: displays and reports match on them, so renaming one silently changes what those surfaces find, and a near-duplicate name splits a history that used to be whole. Adding an event does not put it on any timeline either — the builder decides which records to load.

## Actors and metadata

Personal-value masking has one owner, [AuditMetadataPrivacy](../../app/services/audit_metadata_privacy.rb), called before the audit service logs or persists metadata. Personal changes store their masks directly in metadata; only device history uses the encrypted change-value cell. Readers display the stored values without a second privacy transformation. The [PII guide](../security/pii_encryption.md#audit-events) describes the field masks and device-history storage. Profile and contact writes without an operation ID bypass the five-second creation deduplication window, and their timelines retain stored mutations by event identity. An explicit operation ID suppresses retries of the same operation within five seconds. Eligible structural actions retain their action-specific five-second fingerprints; masked-value equality does not prove a retry or a reversion.

Masking follows personal fields through nested hashes and collections and also applies to values wrapped in a secret or withheld field. Metadata name snapshots, including staff assignment and completion names, retain initials. The exact actor ID and any role metadata are preserved. `Event#user` remains the account association for authorized screens to resolve the actor's current identity, so a masked name snapshot does not remove attribution.

The actor is the authenticated person who performed the action. Public proof and provider-info submissions instead record [PublicAuditActor](../../app/services/public_audit_actor.rb), since anyone can hold a bearer link; the person the submission was made for belongs in metadata rather than in the actor.

`PublicAuditActor` resolves the administrator at `system@mdmat.org`, provisioned by [`bin/rails db:bootstrap`](../infrastructure/setup_and_maintenance.md#bootstrapping-an-environment). Missing that account skips public audit events; public registrations needing a duplicate-review case roll back. Creating a staff administrator alone does not satisfy this dependency.

Metadata stays small and bounded — stable IDs, reason codes, status changes, channel, batch or form identifiers, the failed step. Raw tokens and bearer URLs are credentials and do not belong in a durable row. Notes, identity rationales, and free-text rejection/decline reasons are withheld from audit metadata; the owning workflow's authorized detail view remains responsible for full text. Stored case snapshots and other workflow records still require their own privacy review.

The `Event` model reads request context from `Current`. Background work may have no request context, so pass the actor explicitly. Workflow flags such as `Current.paper_context` belong to their owning service and must be cleared when that scope ends.

## Troubleshooting and changes

| Symptom | Check |
| --- | --- |
| Missing database event | Owning workflow, event validation, the five-second creation fingerprint, and the system audit account for public requests. |
| Stored event missing from the screen | Builder inclusion rules, related-record lookup, and display fingerprint. |
| Duplicate history | Multiple writers for the same business action before adjusting deduplication. |
| Different actions collapsed together | The distinguishing metadata in both creation and display fingerprints. |

The interesting assertion is rarely that an event exists — it is that a genuinely repeated action produces two rows while a retried one produces a single row, which only shows up in a test that exercises the owner rather than `AuditEventService` directly. An export built from the timeline isn't an audit dataset either. For that, query the underlying models in batches.

[Timeline builder tests](../../test/services/applications/audit_log_builder_test.rb), [display deduplication tests](../../test/services/applications/event_deduplication_service_test.rb), and [status-history tests](../../test/models/application_status_change_lifecycle_test.rb) are the references. [Notifications](notifications.md) and [proof review](proof_review_process_guide.md) own their own histories.
