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
| Proof attachment and review | [`ProofAttachmentService`](../../app/services/proof_attachment_service.rb), [`ProofReviewer`](../../app/services/applications/proof_reviewer.rb) |
| Disability certification | [`MedicalCertificationAttachmentService`](../../app/services/medical_certification_attachment_service.rb), [`MedicalCertificationService`](../../app/services/applications/medical_certification_service.rb) |
| Secure provider-info and proof links | [`RequestProviderInfo`](../../app/services/applications/request_provider_info.rb), [`RequestProofResubmission`](../../app/services/applications/request_proof_resubmission.rb), [`SecureRequestRecipientResolver`](../../app/services/applications/secure_request_recipient_resolver.rb) |
| Duplicate detection, review, merging | [`DuplicateDetectionService`](../../app/services/duplicate_detection_service.rb), [review services](../../app/services/duplicate_review_cases), [reconciliation](../../app/services/duplicate_reconciliation), [`DuplicateMergeService`](../../app/services/users/duplicate_merge_service.rb) |
| Audit history and notifications | [`AuditEventService`](../../app/services/audit_event_service.rb), [`NotificationService`](../../app/services/notification_service.rb) |
| Training and evaluation | [`TrainingSessions`](../../app/services/training_sessions), [`Evaluations`](../../app/services/evaluations) |
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

## Merge-integrity lock boundary

A merge can retire a user while another request is editing or creating related work, so participating writers lock the users involved, reload, and recheck eligibility before writing. [`User.lock_for_merge_integrity!`](../../app/models/concerns/user_merge_integrity.rb) locks base `User` rows in ascending ID order within an existing transaction; decisions come from the reloaded objects it returns, and users are locked before their dependent records. The retired-record validation behind this is a backstop, not a substitute.

| Writer | What the lock protects |
| --- | --- |
| [Duplicate merge](../../app/services/users/duplicate_merge_service.rb) | Case and candidate evidence, owned and managed applications, guardian relationships; live blockers rechecked before transfer. |
| [Review-case writers](../../app/services/duplicate_review_cases) and [pair entry](../../app/services/duplicate_reconciliation/review_pair_service.rb) | Participants and evidence before resolution, flags, or audit changes. [Flag sync](../../app/services/duplicate_reconciliation/review_flag_sync_service.rb) handles one constituent at a time. |
| Portal submission and autosave | Guardian authority and application inventory. Submission and new drafts check sibling eligibility; an existing draft's autosave locks its target without repeating that check. |
| [Dependent creation and edits](../../app/controllers/constituent_portal/dependents_controller.rb) | Guardian eligibility, relationships, contact snapshots, replay and admission checks. Standalone relationship creation locks both endpoints. |
| Contact/role edits, sign-in, [password changes](../../app/services/users/password_update_service.rb) | Current eligibility and the submitted credential or reset-token authority. |
| Secure-request issuance | Actor and recipient/delivery-owner inventory before the application, relationships, and resend form; the service retries if that inventory shifts. |

[`AccountRecoveryController`](../../app/controllers/account_recovery_controller.rb) has a stricter variant: users are acquired in ascending ID order, `FOR KEY SHARE` for notification admins and `FOR UPDATE` for the requester, each at its final strength. Replacing that with a later lock upgrade reintroduces the deadlock it avoids.

This applies to the writers listed, not to every `User` update. Paper new-person creation additionally takes a [name/date-of-birth transaction lock](../../app/services/applications/paper_identity_creation_lock.rb) before recomputing identity matches.

**Password-reset issuance sits outside this boundary.** A concurrent contact change can send instructions to an old address or phone; what makes the link safe is token invalidation and a locked redemption, since reset tokens depend on the password, normalized email, and normalized phone ([authentication](../security/authentication_system.md#password-reset-and-account-access)).

## Temporary request context

[`Current`](../../app/models/current.rb) carries the actor and short-lived workflow state. The flags have different consumers, and a flag's name is not evidence of what it bypasses.

| Attribute | Actual effect |
| --- | --- |
| `paper_context` | Paper intake relaxes selected profile and proof validations and changes callback handling. Set and cleared by the owning service or controller. |
| `skip_proof_validation` | Skips proof presence/consistency checks; used by certification-upload requests and test setup. |
| `reviewing_single_proof` | Scoped by the proof reviewer while saving one decision, avoiding whole-application proof validation. |
| `proof_attachment_service_context` | Tells model callbacks that the attachment service owns validation, events, and review timestamps. |
| `resubmitting_proof` | Set and cleared by the portal proof controller; **no application code reads it**. |
| `force_notifications` | Declared but unread — the delivery checks still consult `Thread.current[:force_notifications]`. |
| `test_user_id` | Lets test authentication restore a session, which can bypass the sign-in flow a test means to exercise. |

The readers are in [`ProofManageable`](../../app/models/concerns/proof_manageable.rb), [`ProofConsistencyValidation`](../../app/models/concerns/proof_consistency_validation.rb), [`NotificationDelivery`](../../app/models/concerns/notification_delivery.rb), and [`Authentication`](../../app/controllers/concerns/authentication.rb). Temporary state is restored in `ensure`; paper context in particular is not a way to suppress validations, audit events, or notifications.

## Tests

Service tests for the operation's result and side effects, controller or integration tests for the real caller. Attachment persistence needs the real attachment service rather than a mock.

- [Paper application service](../../test/services/applications/paper_application_service_test.rb) — creation, rollback, follow-up warnings.
- [Proof attachment service](../../test/services/proof_attachment_service_test.rb) — files, status, events.
- [Notification service](../../test/services/notification_service_test.rb) — record creation versus delivery.
- [Duplicate-merge concurrency](../../test/services/users/duplicate_merge_service_concurrency_test.rb) — competing writes at the lock boundary.
