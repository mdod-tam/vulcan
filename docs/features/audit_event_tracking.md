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

The application timeline combines events, status changes, proof reviews, selected notifications, and related profile changes. It can also synthesize a creation entry for older applications without a stored creation event. A visible timeline entry therefore does not prove that a matching `Event` row exists.

## Two different kinds of deduplication

**At creation:** `AuditEventService` checks the previous five seconds for the same action, auditable record, and action-specific fingerprint. It returns `nil` when suppressing a duplicate and raises if the new event fails validation. It skips this check for `application_created` and events without an auditable record.

**At display:** the timeline groups matching fingerprints into one-minute buckets and chooses a representative. It favors creation events, then status changes, then proof reviews/events, then notifications. This changes the display without deleting stored records.

Each business event still needs a single owner. Neither layer substitutes for that: creation-time deduplication is a five-second window, not a concurrency guarantee, and display deduplication only hides what two writers already stored.

Fingerprints are what separate a legitimate repeated action from a duplicate — the blob for an attachment, the case ID for duplicate review, the retired user ID for a merge, the step name for a paper follow-up failure. The creation and display fingerprints are computed separately, so a new action can be distinguished in one layer and collapsed in the other.

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

`paper_identity_no_match_confirmed` remains readable as historical evidence and has no new writer. Historical audit-only rows are not automatically treated as pair decisions.

Action names are an interface: displays and reports match on them, so renaming one silently changes what those surfaces find, and a near-duplicate name splits a history that used to be whole. Adding an event does not put it on any timeline either — the builder decides which records to load.

## Actors and metadata

The actor is the authenticated person who performed the action. Public proof and provider-info submissions instead record [PublicAuditActor](../../app/services/public_audit_actor.rb), since holding a bearer link proves nothing about who is holding it; the person the submission was made for belongs in metadata rather than in the actor.

`PublicAuditActor` resolves the administrator at `system@mdmat.org`, provisioned through [initial account setup](../infrastructure/setup_and_maintenance.md#initial-accounts). Missing that account skips public audit events; public registrations needing a duplicate-review case roll back. Creating a staff administrator alone does not satisfy this dependency.

Metadata stays small and bounded — stable IDs, reason codes, status changes, channel, batch or form identifiers, the failed step. Raw tokens and bearer URLs are credentials and do not belong in a durable row, and personal information beyond what the event needs makes the audit trail itself a disclosure surface. Bounded generated events say nothing about the records around them: staff-written rationales and stored case snapshots carry their own privacy questions.

The `Event` model reads request context from `Current`. Background work may have no request context, so pass the actor explicitly. Workflow flags such as `Current.paper_context` belong to their owning service and must be cleared when that scope ends.

## Troubleshooting and changes

| Symptom | Check |
| --- | --- |
| Missing database event | Owning workflow, event validation, the five-second creation fingerprint, and the system audit account for public requests. |
| Stored event missing from the screen | Builder inclusion rules, related-record lookup, and display fingerprint. |
| Duplicate history | Multiple writers for the same business action before adjusting deduplication. |
| Different actions collapsed together | The distinguishing metadata in both creation and display fingerprints. |

The interesting assertion is rarely that an event exists — it is that a genuinely repeated action produces two rows while a retried one produces a single row, which only shows up in a test that exercises the owner rather than `AuditEventService` directly. An export built from the timeline is not an audit dataset either; the underlying models, queried in batches, are.

[Timeline builder tests](../../test/services/applications/audit_log_builder_test.rb), [display deduplication tests](../../test/services/applications/event_deduplication_service_test.rb), and [status-history tests](../../test/models/application_status_change_lifecycle_test.rb) are the references. [Notifications](notifications.md) and [proof review](proof_review_process_guide.md) own their own histories.
