# Service Architecture

A service performs one business operation — submit an application, attach a proof, send a request, merge two records.

Controllers choose the operation and deal with its result; models hold data and shared rules.

Most services are in [`app/services/`](../../app/services); some inherit [`BaseService`](../../app/services/base_service.rb) and others are plain class methods.

A typical operation runs in five moves:

1. The controller establishes who is acting and on what.
2. The workflow service validates the request and coordinates the changes.
3. Models enforce shared rules, with related writes inside a transaction.
4. The owning service records history and arranges follow-up.
5. The caller handles success, failure, or a warning about follow-up that did not complete.

[Paper intake](paper_application_architecture.md) is the fullest example — `Admin::PaperApplicationsController` → `PaperApplicationService#create`, with user creation and document handling delegated onward.

## Who owns what

| Operation | Owner |
| --- | --- |
| Portal submission and draft saving | [`ApplicationCreator`](../../app/services/applications/application_creator.rb), [`AutosaveService`](../../app/services/applications/autosave_service.rb) |
| Paper application creation | [`PaperApplicationService`](../../app/services/applications/paper_application_service.rb), with identity facts in [`PaperIdentityReview`](../../app/services/applications/paper_identity_review.rb) and admission rules in [`PaperApplicationEligibility`](../../app/services/applications/paper_application_eligibility.rb) |
| Guardian/dependent creation and contact choices | [`GuardianDependentManagementService`](../../app/services/applications/guardian_dependent_management_service.rb), [guardian quick-create](../../app/services/applications/paper_guardian_quick_create_service.rb) |
| Proof attachment and review | [`ProofAttachmentService`](../../app/services/proof_attachment_service.rb), [`ProofReviewer`](../../app/services/applications/proof_reviewer.rb); submitted files resolve through [`UploadedDocument`](../../app/services/uploaded_document.rb) |
| Disability certification | [`MedicalCertificationAttachmentService`](../../app/services/medical_certification_attachment_service.rb), [`MedicalCertificationService`](../../app/services/applications/medical_certification_service.rb); manual uploads resolve through [`UploadedDocument`](../../app/services/uploaded_document.rb) |
| Secure provider-info and proof links | [`RequestProviderInfo`](../../app/services/applications/request_provider_info.rb), [`RequestProofResubmission`](../../app/services/applications/request_proof_resubmission.rb), [`SecureRequestRecipientResolver`](../../app/services/applications/secure_request_recipient_resolver.rb) |
| Duplicate detection, review, merging | [`DuplicateDetectionService`](../../app/services/duplicate_detection_service.rb), [review services](../../app/services/duplicate_review_cases), [reconciliation](../../app/services/duplicate_reconciliation), [`DuplicateMergeService`](../../app/services/users/duplicate_merge_service.rb) |
| Audit history and notifications | [`AuditEventService`](../../app/services/audit_event_service.rb), [`NotificationService`](../../app/services/notification_service.rb) |
| Training and evaluation | [`TrainingSessions`](../../app/services/training_sessions), [`Evaluations`](../../app/services/evaluations) |
| Equipment needs, ordering, and corrections | [`EquipmentNeeds::Writer`](../../app/services/equipment_needs/writer.rb), [`Equipment::Ordering`](../../app/services/equipment/ordering.rb), [`Equipment::Correction`](../../app/services/equipment/correction.rb) |
| Public authentication limits | [`AuthRateLimit`](../../app/services/auth_rate_limit.rb) |

## Result contracts differ

There is no single return convention, and truthiness is not a safe test — a returned object or hash can describe a failure.

| Result | How to read it |
| --- | --- |
| `BaseService::Result` | `success?` / `failure?`, plus `message` and `data`. |
| Attachment-service hash | `result[:success]`, with `result[:error]` on failure. |
| Paper intake boolean | `errors`, `commit_confirmed?`, and `warning_message` — see below. |
| Audit or notification record | The record, or `nil`. Creating a record proves nothing about external delivery. |

### Paper intake can succeed while its follow-up fails

An `after_commit` callback can raise after the application is already committed. Reporting that as a failed save invites staff to enter the application a second time, so [`PaperApplicationService#create`](../../app/services/applications/paper_application_service.rb) distinguishes three outcomes: `false` means nothing was committed and the form should re-render with `errors`; `true` with a confirmed commit means the application exists, with `warning_message` covering callbacks, delivery, or reconciliation that needs attention; `true` with an unconfirmed commit means the database could not confirm the write, and staff are sent to the applications list to check before retrying.

The service checks durable state when handling transaction errors rather than trusting an in-memory `persisted?`, and does not rerun a callback that may have half-completed.

## State, history, and delivery stay together

- Lifecycle changes go through [`Application#transition_status!`](../../app/models/application.rb) and [`#reconcile_workflow_state!`](../../app/models/concerns/application_status_management.rb); a raw status write skips history and follow-up.
- Proof-rejection audit and resubmission delivery are already coordinated by [`ProofReview`](../../app/models/proof_review.rb) and `RequestProofResubmission` — a second sender duplicates the notice.
- `NotificationService` has a `deliver: false` mode that records without sending, and some actions are permanently record-only. Its audit events are opt-in ([notifications](../features/notifications.md)).
- `AuditEventService` writes events; [`EventDeduplicationService`](../../app/services/applications/event_deduplication_service.rb) only chooses what a timeline displays. Display deduplication does not make a write idempotent.
- Secure requests record their logical recipient, delivery owner, and source at issuance, through the recipient resolver and [issuance integrity service](../../app/services/applications/secure_request_issuance_integrity.rb). Historical forms missing that ownership cannot have it reconstructed from today's contact data.

### Evaluation report state

[`Evaluations::SubmissionService`](../../app/services/evaluations/submission_service.rb) completes the report and records its audit event in the same transaction. Report lifecycle uses completed status, and `report_submitted_at` records when it was submitted, with unknown historical times left nullable.

The service locks the application before the evaluation and rechecks approval and the assigned actor. An assigned administrator can record outside-specialist consultation from requested, scheduled, or confirmed status with its actual completion time and written context, without inventing a planned appointment or trials. Direct reports retain their existing requirements. [EquipmentNeeds::Writer.initialize_from!](../../app/services/equipment_needs/writer.rb) participates in this transaction, initializing once without creating physical equipment. Confirmation delivery follows the saved report; an enqueue failure does not undo the report or needs.

### Equipment purchasing

[EquipmentNeeds::Writer](../../app/services/equipment_needs/writer.rb) owns initial recommendations-to-needs mapping and whole-list quantity edits. It checks the initialization marker and every retained row's version under the application lock. Zero rows preserve removal history; adding a replacement model never rewrites the source report. The first reasoned staff save records `equipment_needs_updated` even for an unchanged empty list; later unchanged saves do not emit another decision event. Automatic initialization and this existing audit event distinguish an outside-catalog recommendation awaiting a catalog decision from a staff-confirmed empty list, without another marker column or writer. Reads do not seed data.

[Application](../../app/models/application.rb) owns the shared `equipment_procurement_eligible` scope and predicate, derived fulfillment badges, and `equipment_source_report`. The source reader uses retained need provenance or the original initialization event before falling back to a completed report; views consume the same reader. Archived records retain readable history but cannot receive new procurement assignments; an unconfirmed outside-catalog recommendation uses a neutral badge when purchasing eligibility ends.

[Equipment::Ordering](../../app/services/equipment/ordering.rb) records a shared PO, consumes selected remaining quantities into one item per unit, and relinks detached devices without consuming quantities. [Equipment::Correction](../../app/services/equipment/correction.rb) owns individual device and shared-header factual corrections. Models validate quantities, dates, relationship and identity invariants; controllers authorize requests and route errors back to their forms. [Equipment::Mutation](../../app/services/equipment/mutation.rb) shares the same admin, eligibility, version, sorted application-lock, and audit rules across these writers. Needs and order assignments recheck approved equipment eligibility; corrections preserve recorded real-world facts after archival.

Writers lock affected applications first, followed by needs, purchase orders, and items in sorted order. They recheck versions and membership before persisting. Domain changes and `AuditEventService.log` events share the transaction; each successful mutation receives a distinct operation ID so rapid corrections retain their history. Stale retries raise an operator-visible conflict and add no successful-change event. Database constraints enforce vendor/PO-number, application/product need, and active-device identity uniqueness.

Equipment correction forms use Turbo's built-in submit-button disabling and progress labels. [EquipmentFormHandling](../../app/controllers/concerns/admin/equipment_form_handling.rb) renders read-only review previews as Turbo Stream replacements from the existing edit template; ordinary HTML requests use that same template. Turbo's native autofocus moves focus to the preview heading. Invalid saves return HTML 422 with the submitted draft and version checks; a valid review token is retained, while an expired or invalid token returns the form to **Review correction**. Error summaries retain focus on rejected saves, and successful saves redirect with HTTP 303. The correction writer remains responsible for validating the confirmed impact and current versions.

The [procurement migration](../../db/migrate/20261013120000_add_equipment_procurement.rb) adds the existing evaluations table's assessment-source CHECK with `validate: false`, which enforces new writes without scanning existing rows. It commits before the [separate validation migration](../../db/migrate/20261014120000_validate_evaluation_assessment_source.rb) scans existing rows, releasing the schema-change lock before validation. Both use Rails' default migration transactions. Reversing validation recreates the same enforced, unvalidated CHECK without removing the column or procurement tables.

Queue readers derive current state from needs, actual device products, current PO associations and shipment dates. **Equipment by Type**, including historical periods, counts active devices with current POs using actual products and PO sent dates; purchasing needs contribute no units. Device identifiers stay out of bid exports. Carrier tracking links are generated by [EquipmentHelper](../../app/helpers/equipment_helper.rb) from an allowlisted official HTTPS destination and encoded tracking number; no carrier request or status synchronization runs on the server.

[Equipment::RequestParameters](../../app/services/equipment/request_parameters.rb) normalizes equipment navigation context and submitted version maps; controllers use it directly. [Equipment::AuditRecords](../../app/queries/equipment/audit_records.rb) batches historical label lookups from `Event#field_change_pairs`, including restored encrypted changes. Controllers prepare those records for full-page and proof-review Turbo history; presentation helpers format the supplied records without querying. `PurchaseOrder#equipment_history` includes events for devices moved away from the order.

## Merge-integrity lock boundary

A merge can retire a user while another request is editing or creating related work, so participating writers lock the users involved, reload, and recheck eligibility before writing. [`User.lock_for_merge_integrity!`](../../app/models/concerns/user_merge_integrity.rb) locks base `User` rows in ascending ID order within an existing transaction; decisions come from the reloaded objects it returns, and users are locked before their dependent records. The retired-record validation behind this is a backstop, not a substitute.

| Writer | What the lock protects |
| --- | --- |
| [Duplicate merge](../../app/services/users/duplicate_merge_service.rb) | Case and candidate evidence, owned and managed applications, guardian relationships; live blockers rechecked before transfer. |
| [Review-case writers](../../app/services/duplicate_review_cases) and [pair entry](../../app/services/duplicate_reconciliation/review_pair_service.rb) | Participants and evidence before resolution, flags, or audit changes. [Flag sync](../../app/services/duplicate_reconciliation/review_flag_sync_service.rb) handles one constituent at a time. |
| Portal submission and autosave | Guardian authority and application inventory. Without an application id, both resume the actor's existing draft for the applicant from the locked inventory; otherwise submission and new drafts check sibling eligibility. An existing draft's autosave locks its target without repeating that check. |
| [Dependent creation and edits](../../app/controllers/constituent_portal/dependents_controller.rb) | Guardian eligibility, relationships, contact snapshots, replay and admission checks. Standalone relationship creation locks both endpoints. |
| Contact/role edits, sign-in, [password changes](../../app/services/users/password_update_service.rb) | Current eligibility and the submitted credential or reset-token authority. |
| Secure-request issuance | Actor and recipient/delivery-owner inventory before the application, relationships, and resend form; the service retries if that inventory shifts. |

[`AccountRecoveryController`](../../app/controllers/account_recovery_controller.rb) has a stricter variant: users are acquired in ascending ID order, `FOR KEY SHARE` for notification admins and `FOR UPDATE` for the requester, each at its final strength. Replacing that with a later lock upgrade reintroduces the deadlock it avoids.

This applies to the writers listed, not to every `User` update. Paper new-person creation additionally takes a [name/date-of-birth transaction lock](../../app/services/applications/paper_identity_creation_lock.rb) before recomputing identity matches.

**Password-reset issuance sits outside this boundary.** A concurrent contact change can send instructions to an old address or phone; what makes the link safe is token invalidation and a locked redemption, since reset tokens depend on the password, normalized email, and normalized phone ([authentication](../security/authentication_system.md#password-reset-and-account-access)).

## Portal autosave ordering

[`Applications::AutosaveRevisions`](../../app/models/applications/autosave_revisions.rb) wraps the application for `AutosaveService` and `ApplicationCreator`. The portal form receives a random UUID identifying that page. The value object also supplies the next revision when rendering the form. Each edit has a rising revision; Save/Submit carries a revision covering the whole snapshot. The page ID is ordering bookkeeping, not authorization: the existing actor/applicant checks and locks still control access.

Within the existing participant/application locks, a field save compares its revision with that page's field revision and full-form boundary. An older or duplicate save returns `superseded`, with the current value and revision, without changing data, progress, or audit events. A successful full-form save sets the boundary for every field to the greater of its submitted revision and the highest revision already stored for that page. This includes a previously unseen page ID, so a delayed first autosave cannot overwrite its full Save. A refused or rolled-back save advances nothing. The JSONB `applications.autosave_revisions` column commits with the values; it stores page IDs and counters, not field values. Even a first disability edit persists a draft so its user-owned value and revision share a transaction.

Page IDs do not expire. Drafts retain other pages' ordering entries on full Save: deleting them would allow an older request from another open tab to overwrite that tab's newer edit. Successful portal submission clears the metadata in the same transaction; a refused or rolled-back submission retains it. Submitted applications reject autosaves. Draft metadata can still grow with the number of pages used until submission.

Missing or malformed metadata refuses a field autosave with guidance to use Save Application. A full form instead skips ordering for that request and saves normally; bookkeeping never rejects an otherwise valid full Save. Valid metadata orders field saves within that page. A late full Save with an older revision can still overwrite a newer field save: the browser prevents that ordering during normal use by stamping Save above earlier edits and freezing controls during submission, rather than the server rejecting the full form. Separate tabs remain last-write-wins, and unversioned full forms do not establish a boundary. This is not collaborative editing or guaranteed offline saving.

Full saves apply submitted blank provider fields as clears, while omitted fields remain unchanged. During Save/Submit the browser freezes form controls after Turbo captures the submitted values; validation feedback cannot re-enable a second submit. Failure or cached-page restoration makes those controls usable again.

Deployment requires the additive migration before the new server code. All writers must enforce the protocol before the new JavaScript's parallel departure saves can rely on it; avoid serving new assets alongside old workers. Older open pages may have unversioned autosaves refused and should use Save Application or refresh. Full forms with missing or malformed metadata remain supported for legacy pages; current forms also work without JavaScript. On rollback, restore the old assets and application code before removing the column.

## Temporary request context

[`Current`](../../app/models/current.rb) carries the actor and short-lived workflow state. The flags have different consumers, and a flag's name is not evidence of what it bypasses.

| Attribute | Actual effect |
| --- | --- |
| `paper_context` | Paper intake relaxes selected profile and proof validations and changes callback handling. Set and cleared by the owning service or controller. |
| `skip_proof_validation` | Skips proof presence/consistency checks; used by certification-upload requests and test setup. |
| `reviewing_single_proof` | Scoped by the proof reviewer while saving one decision, avoiding whole-application proof validation. |
| `proof_attachment_service_context` | Tells model callbacks that the attachment service owns validation, events, and review timestamps. |
| `force_notifications` | Declared but unread — the delivery checks still consult `Thread.current[:force_notifications]`. |
| `test_user_id` | Lets test authentication restore a session, which can bypass the sign-in flow a test means to exercise. |

The readers are in [`ProofManageable`](../../app/models/concerns/proof_manageable.rb), [`ProofConsistencyValidation`](../../app/models/concerns/proof_consistency_validation.rb), [`NotificationDelivery`](../../app/models/concerns/notification_delivery.rb), and [`Authentication`](../../app/controllers/concerns/authentication.rb). Temporary state is restored in `ensure`; paper context in particular is not a way to suppress validations, audit events, or notifications.

## Tests

Service tests for the operation's result and side effects, controller or integration tests for the real caller. Attachment persistence needs the real attachment service rather than a mock.

- [Paper application service](../../test/services/applications/paper_application_service_test.rb) — creation, rollback, follow-up warnings.
- [Proof attachment service](../../test/services/proof_attachment_service_test.rb) — files, status, events.
- [Notification service](../../test/services/notification_service_test.rb) — record creation versus delivery.
- [Duplicate-merge concurrency](../../test/services/users/duplicate_merge_service_concurrency_test.rb) — competing writes at the lock boundary.
