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
| `Applications::PaperApplicationService` | `app/services/applications/paper_application_service.rb` | Creates admin-entered paper applications through the `new`/`create` admin intake route. **Result contract:** `false` means nothing committed (a *confirmed* rollback) and the caller must re-render the form with `errors`. `true` means the write was not a confirmed rollback, with `warning_message` present when a post-commit step failed -- but check `commit_confirmed?`: when the verifying query itself fails the result is `true` and unconfirmed, and the caller must route to the applications list rather than to a record that may not be there. Commit state is established by querying the database, never by `application.persisted?` -- a rollback clears the id, and an `after_commit` callback can raise after the data is durable (`ProofReview` does, on every rejected proof). New self and new-dependent branches take the shared transaction-scoped name+DOB identity lock and consume `PaperIdentityReview` without re-deriving it. Selected guardian and dependent rows are locked and requalified before any contact, relationship, or application write; an existing dependent must already have the selected guardian relationship. | Boolean plus `errors` / `warning_message` |
| `Applications::PaperIdentityReview` | `app/services/applications/paper_identity_review.rb` | **Sole owner** of paper self-applicant, guardian, and dependent review facts, candidate presentation/selectability, outcomes, and signed issuance/verification. Dependent facts deterministically apply guardian/dependent contact strategies and bind guardian plus relationship context. Preview and every writer consume the same owner. | `PaperIdentityReview::Result` (keyword-init struct) |
| `Applications::PaperIdentityCreationLock` | `app/services/applications/paper_identity_creation_lock.rb` | Sole owner of the transaction-scoped Postgres name/date-of-birth advisory lock shared by every retained paper new-person writer. Callers must already own an open transaction; competing writers wait for the same identity key until that transaction ends. Missing transaction ownership and database lock failures raise. | `ActiveRecord::Result` from acquiring the lock |
| `Applications::PaperGuardianQuickCreateService` | `app/services/applications/paper_guardian_quick_create_service.rb` | Canonical JSON paper guardian writer. Recomputes review under the shared identity lock, requalifies selected candidates under row lock, creates with `skip_user_lookup`, records one bounded override event when applicable, and opens no case. | `BaseService::Result` with state, review, user, and created flag |
| `Applications::PaperIdentityDecision` | `app/services/applications/paper_identity_decision.rb` | Issues and verifies the signed attestation that staff looked at specific candidates and decided none is this applicant. Token is `v1:<issued_at>:<hmac>`; nothing about the applicant travels in it. Bound to the context, admin, an HMAC of the full detection fact set, an HMAC of the **presented candidate snapshot including each row's `selectable` state**, the reason codes, and the issue time. 30-minute expiry. The token is stateless and is never marked spent. Every canonical new-person writer takes `PaperIdentityCreationLock`, then recomputes the candidate snapshot and verifies the decision while holding that lock; serialization plus locked recomputation rejects a competing replay. | `PaperIdentityDecision::Result` |
| `Applications::GuardianDependentManagementService` | `app/services/applications/guardian_dependent_management_service.rb` | Creates a new paper dependent for a locked, eligible selected guardian; applies contact strategies, verifies identity under the shared lock, records a successful override when needed, and creates the relationship in the outer paper transaction. It does not create guardians or reuse unrelated existing dependents. | `BaseService::Result` on the success path |
| `Applications::MedicalCertificationService` | `app/services/applications/medical_certification_service.rb` | Requests disability certification from a provider. | `BaseService::Result` |
| `Applications::EventService` | `app/services/applications/event_service.rb` | Logs guardian/dependent application submission and update events. | `Event` or `nil` |
| `Applications::EventDeduplicationService` | `app/services/applications/event_deduplication_service.rb` | Deduplicates timeline inputs for display. | Array |
| `DuplicateDetectionService` | `app/services/duplicate_detection_service.rb` | Evaluates exact contact duplicates and soft name+DOB/address signals. Public registration and portal dependent creation call it for their contexts; paper self, guardian quick-create, and dependent writers reach it through `Applications::PaperIdentityReview`, which owns their normalized facts and inline decisions. | `BaseService::Result` with `DuplicateDetectionService::Result` data |
| `DuplicateReviewCases::CreateService` | `app/services/duplicate_review_cases/create_service.rb` | Opens idempotent duplicate-review cases after the subject user is persisted, stores sanitized candidate/metadata snapshots, syncs `needs_duplicate_review`, and logs case-opened audit events. | `BaseService::Result` |
| `DuplicateReviewCases::ResolutionService` | `app/services/duplicate_review_cases/resolution_service.rb` | Resolves an open case without moving data, locking actor + subject before the case, syncing the subject `needs_duplicate_review` flag, and logging `duplicate_review_case_resolved`. Both the determination and the status are **server-owned**: it always records `NON_MERGE_DETERMINATION` (`keep_separate`) and `NON_MERGE_STATUS` (`resolved_ignored`), and takes neither as a parameter, because only a completed identity decision may close a case and that decision has exactly one outcome. `Admin::DuplicateReviewsController` rejects a conflicting `determination` or `resolution_action` before calling the service, so a stale form cannot resolve a case under an intent the server would reinterpret. `resolved_approved` remains mapped as a legacy readable status that nothing writes. Resolving recomputes two independent effects from remaining open cases — the submission gate releases when no open `registration_soft_match` case remains, and the review flag clears when no open case of any source remains. `same_person_confirmed` is reserved to the merge service. | `BaseService::Result` |
| `Users::DuplicateMergeService` | `app/services/users/duplicate_merge_service.rb` | Same-person merge for one selected open `registration_soft_match` case: locks active actor + canonical + duplicate base users, the selected case/candidate, and the complete participant application inventory; preflights blockers; transfers supported ownership; clears the retired row's email/phone/phone type; resolves only the selected case; and emits one `duplicate_user_merged` event in the same transaction. | `BaseService::Result` |
| `DuplicateReviewCases::ClearFlagService` | `app/services/duplicate_review_cases/clear_flag_service.rb` | Clears a subject's `needs_duplicate_review` flag outside of any case (requires a rationale), locking the subject row, refusing if an open case still exists, and logging `duplicate_review_flag_cleared`. | `BaseService::Result` |
| `Applications::SecureRequestIssuanceIntegrity` | `app/services/applications/secure_request_issuance_integrity.rb` | Shared bounded-retry lock owner for provider-info and proof-resubmission issuance: locks the complete known base-user participant set before the exact application, guardian relationships, and optional resend form; retries the whole transaction if the locked inventory reveals another participant. | Yields a locked context or raises a bounded conflict |
| `AuthRateLimit` | `app/services/auth_rate_limit.rb` | Centralizes sign-in, account-access, and account-recovery throttles using policy-backed per-action/per-scope limits and digest-only identifiers. | Raises `AuthRateLimit::ExceededError` on denial |
| `PublicAuditActor` | `app/services/public_audit_actor.rb` | Attributes unauthenticated security/rate-limit audit events to the configured system audit actor without promoting a public request to a real user. | `Event` or `nil` |

Related docs:

- Paper intake: [`docs/development/paper_application_architecture.md`](paper_application_architecture.md)
- Audit/event tracking: [`docs/features/audit_event_tracking.md`](../features/audit_event_tracking.md)
- Notifications: [`docs/features/notifications.md`](../features/notifications.md)
- Document signing: [`docs/development/docuseal_integration_guide.md`](docuseal_integration_guide.md)

### Merge-integrity lock boundary

Merge-integrity coordination covers only the writers traced to the same-person merge result. Production owners acquire base `User` locks in ascending id order before dependent rows; `User.lock_for_merge_integrity!` is the shared `FOR UPDATE` entry point, with the recovery-request exception documented below for its notification foreign keys:

- merge: active actor, canonical, duplicate → selected case → matching candidate evidence → all applications owned or managed by either participant;
- duplicate-review create/clear/resolve: actor and affected subject/candidates → case rows and audit mutation;
- portal final submission: actor/applicant/known guardian participants → guardian relationships → the applicant's full locked application inventory, against which the shared `Application.sibling_application_eligibility_error` policy is evaluated. The pending-review gate is checked here too: an open `registration_soft_match` case whose subject is the applicant refuses the submission. It takes no lock of its own — this transaction already holds the applicant's `User` row, and both writers that can resolve a case (`DuplicateReviewCases::ResolutionService`, `Users::DuplicateMergeService`) acquire that same row first, so the case read is always of committed state;
- portal autosave: actor/applicant/known guardian participants → guardian relationships → for a new draft the applicant's full locked inventory plus the shared sibling policy; for a draft that already exists, the target application row alone. A persisted draft is therefore not re-checked against siblings on each keystroke — that policy is enforced at submission by `ApplicationCreator`, under lock, against the full inventory. Merge serialization is unaffected either way, because the merge locks a superset (every application owned or managed by either participant);
- recovery-request creation: requester + admin-notification FK inventory in ascending id order with `FOR KEY SHARE`, then the requester upgraded through `lock_for_merge_integrity!` before recovery/notification rows; secure-request creation: actor/requester/recipient inventory → application/relationship/secure-form rows;
- primary contact edits, role conversion, and password-only sign-in: the affected user(s) before re-resolving authority and writing;
- password writes — both password-reset completion (token re-resolved under lock) and the signed-in/forced password change (`Users::PasswordUpdateService`, which re-runs the password challenge against the locked row): the affected user before re-checking `public_login_active?` and writing;
- guardian-managed dependent creation: the guardian plus every duplicate-review candidate that will be persisted, in one ascending-id call before any write. The guardian must still be `public_login_active?` and a constituent under lock; contact strategies are re-derived from that locked guardian. Two admission questions are answered inside that lock before any write: the per-form `portal_creation_key` resolves a request replay, which returns the original outcome with zero writes, and the guardian-scoped name+DOB rule (via `Users::Constituent.find_duplicates`) refuses a second dependent with the same canonical identity. The key is resolved within the authenticated guardian's own namespace, and the partial composite unique index on `[guardian_id, portal_creation_key]` is scoped the same way. A stored `portal_creation_fingerprint` — a versioned server-keyed HMAC over everything semantically submitted — distinguishes a true replay from a reused key carrying changed input, which is refused as a stale form rather than silently discarded. The new dependent `User`, the authorizing `GuardianRelationship`, and — for a soft match — the `portal_dependent` review case, its candidate rows, the subject's `needs_duplicate_review` flag, and the case-opened audit event then commit or roll back together, with no compensating delete. A participant deleted between detection and the lock fails closed with the ordinary retry response rather than a server error;
- guardian-managed dependent profile edits: dependent and guardian, then the authorizing `GuardianRelationship` row itself. The guardian, as the authenticated actor, must still be `public_login_active?` and a constituent under lock; the dependent, which never authenticates, is disqualified only by `merged?`. Contact *values* are also derived inside the lock, from the locked guardian: a guardian contact strategy snapshots the guardian's own email, phone, and delivery preference into the dependent's stored contact, and `User#effective_phone` prefers that stored `dependent_phone`, so a pre-lock snapshot would become durable contact truth.

This inventory is a bounded guarantee for the listed merge-adjacent writers and their deterministic concurrency tests. It does not establish system-wide `User` serialization or universal deadlock freedom for unrelated services.

Not every merge-adjacent hazard is a lock-ordering problem. Reset-link authority is the counterexample: a link issued to a contact route that a later merge discards was legitimately issued at the time, so no amount of locking at issuance invalidates it afterwards. That one is closed by *revocation* — the `:password_reset` token fingerprint covers the password digest plus normalized email and phone, so changing either contact route kills outstanding links. See [`docs/security/authentication_system.md`](../security/authentication_system.md).

Named exclusion — a merge-adjacent writer deliberately *not* inside this boundary:

- account-access **issuance** (`PasswordsController#create`). The identifier lookup and delivery-route selection are unlocked, so a merge committing mid-request can still send instructions to the contact it just discarded. This is deliberate: token revocation (above), not lock ordering, is what keeps such a link from being usable. The residual effect is a wasted message to a stale address or number, not reset authority.

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
- Self-applicant, existing self-applicant, existing dependent, and new-dependent scenarios are handled in the service; new guardians use the separate JSON quick-create writer.
- New guardians are created only by `Applications::PaperGuardianQuickCreateService`; final submission requires its saved id or an existing guardian selection. `Applications::GuardianDependentManagementService` owns new-dependent creation and its relationship, while existing-dependent selection requires an already on-file relationship and never creates one from a raw id.
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
- `security_key_recovery_approved` is deliberately email-only and records `delivery_route_reason: "email_only"` because there is no printed-letter delivery path for that account-access notice.
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

### 4.6 · Auth Rate Limits and Public Audits

`AuthRateLimit` is the shared gate for public auth throttles:

- `SessionsController#create` uses action `:sign_in_attempt` and scope `:ip`.
- `PasswordsController#create` uses action `:account_access` with `:ip`, `:contact_ip`, and matched `:user_ip` scopes.
- `AccountRecoveryController#create` uses action `:account_recovery` with `:ip`, `:contact_ip`, and matched `:user_ip` scopes.

`Policy.auth_rate_limit_for` delegates to `AuthRateLimit.limit_config_for`, so policy rows and service defaults share the same allowlist and fallback behavior. Cache identifiers are HMAC/SHA digests, not raw contacts or IP addresses. Rate-limited public requests log through `PublicAuditActor`, which uses `system@mdmat.org` when present and otherwise skips the audit with a warning instead of inventing a privileged actor.

Primary tests:

- `test/services/auth_rate_limit_test.rb`
- `test/services/public_audit_actor_test.rb`
- `test/models/policy_auth_rate_limit_test.rb`

### 4.7 · Training and Evaluation Services

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
