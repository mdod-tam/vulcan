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

[Paper intake](paper_application_architecture.md) is the fullest example — `Admin::PaperApplicationsController` → `PaperApplicationService#create`, with applicant intake, document dispositions and confirmed-commit follow-up delegated to three paper-specific objects. The service retains transaction classification and the controller-facing boolean, errors and warnings.

## Who owns what

| Operation | Owner |
| --- | --- |
| Portal submission and draft saving | [`ApplicationCreator`](../../app/services/applications/application_creator.rb), [`AutosaveService`](../../app/services/applications/autosave_service.rb) |
| Paper application creation | [`PaperApplicationService`](../../app/services/applications/paper_application_service.rb), with identity facts in [`PaperIdentityReview`](../../app/services/applications/paper_identity_review.rb) and admission rules in [`AdmissionEligibility`](../../app/services/applications/admission_eligibility.rb) |
| Guardian/dependent creation and contact choices | [`GuardianDependentManagementService`](../../app/services/applications/guardian_dependent_management_service.rb), [guardian quick-create](../../app/services/applications/paper_guardian_quick_create_service.rb) |
| Proof attachment and review | [`ProofAttachmentService`](../../app/services/proof_attachment_service.rb), [`ProofReviewer`](../../app/services/applications/proof_reviewer.rb); submitted files resolve through [`UploadedDocument`](../../app/services/uploaded_document.rb) |
| Disability certification | [`DisabilityCertificationAttachmentService`](../../app/services/disability_certification_attachment_service.rb), [`DisabilityCertificationService`](../../app/services/applications/disability_certification_service.rb); manual uploads resolve through [`UploadedDocument`](../../app/services/uploaded_document.rb) |
| Secure provider-info and proof links | [`RequestProviderInfo`](../../app/services/applications/request_provider_info.rb), [`RequestProofResubmission`](../../app/services/applications/request_proof_resubmission.rb), [`SecureRequestRecipientResolver`](../../app/services/applications/secure_request_recipient_resolver.rb) |
| Duplicate detection, review, merging | [`DuplicateDetectionService`](../../app/services/duplicate_detection_service.rb), [review services](../../app/services/duplicate_review_cases), [reconciliation](../../app/services/duplicate_reconciliation), [`DuplicateMergeService`](../../app/services/users/duplicate_merge_service.rb) |
| Audit history and notifications | [`AuditEventService`](../../app/services/audit_event_service.rb), [`NotificationService`](../../app/services/notification_service.rb) |
| Training coverage and appointments | [`Applications::TrainerAssignment`](../../app/services/applications/trainer_assignment.rb), [`TrainingManagement`](../../app/models/concerns/training_management.rb), named [`TrainingSessions`](../../app/services/training_sessions) commands, [`TrainingSessionNotifier`](../../app/services/training_session_notifier.rb) |
| Evaluation | [`Evaluations`](../../app/services/evaluations) |
| Authorized product history | [`Applications::ProductHistory`](../../app/queries/applications/product_history.rb) over an already-authorized Application relation |
| Public product resources | [`ProductResource`](../../app/models/product_resource.rb), [`ProductResources::Writer`](../../app/services/product_resources/writer.rb), existing [`UploadedDocument`](../../app/services/uploaded_document.rb) intake |
| Equipment needs, bids, stock, ordering, and corrections | [`EquipmentNeeds::Writer`](../../app/services/equipment_needs/writer.rb), [`Equipment::Bidding`](../../app/services/equipment/bidding.rb), [`Equipment::Ordering`](../../app/services/equipment/ordering.rb), [`Equipment::StockReceipt`](../../app/services/equipment/stock_receipt.rb), [`Equipment::StockAllocation`](../../app/services/equipment/stock_allocation.rb), [`Equipment::Shipment`](../../app/services/equipment/shipment.rb), [`Equipment::Correction`](../../app/services/equipment/correction.rb) |
| ICC cost tracking and filing | [`Icanconnect`](../../app/services/icanconnect), [operating guide](../operations/icanconnect.md) |
| Public authentication limits | [`AuthRateLimit`](../../app/services/auth_rate_limit.rb) |

[`AdmissionEligibility`](../../app/services/applications/admission_eligibility.rb) also owns the admission decision used by portal submission/autosave and admin user presentation. Portal writers supply their locked application inventory, exclude the target draft, and ignore unsaved siblings; advisory reads do not replace those locked checks. Active or pending applications take precedence. Only an approved application's date starts the waiting duration, so a recent rejection or archive alone does not postpone admission. Approved applications remain blocking even after that duration elapses.

The Result exposes the approved waiting end separately from its admission reason: the model's create validation checks the waiting duration, while writers and presentation consume the admission decision. `Policy.waiting_period_years` supplies the duration. `Application#service_window_end_date` retains its separate per-application entitlement calculation for training/evaluation, including its missing-date and end-date boundary behavior.

## Result contracts differ

There is no single return convention, and truthiness is not a safe test — a returned object or hash can describe a failure.

| Result | How to read it |
| --- | --- |
| `BaseService::Result` | `success?` / `failure?`, plus `message` and `data`. |
| Attachment-service hash | `result[:success]`, with `result[:error]` on failure, and `result[:duration_ms]`. [`AttachmentOperation`](../../app/services/attachment_operation.rb) builds it and logs one outcome line. Each service keeps its own failure contract: proof methods and `update_certification_status` return the error, while certification attach, accept, and reject raise it. |
| Paper intake boolean | `errors`, `commit_confirmed?`, and `warning_message` — see below. |
| Audit or notification record | The record, or `nil`. A created record doesn't mean anything was delivered. |

### Paper intake can succeed while its follow-up fails

An `after_commit` callback can raise after the application is already committed. Reporting that as a failed save invites staff to enter the application a second time, so [`PaperApplicationService#create`](../../app/services/applications/paper_application_service.rb) distinguishes three outcomes: `false` means nothing was committed and the form should re-render with `errors`; `true` with a confirmed commit means the application exists, with `warning_message` covering callbacks, delivery, or reconciliation that needs attention; `true` with an unconfirmed commit means the database could not confirm the write, and staff are sent to the applications list to check before retrying.

The service checks durable state when handling transaction errors rather than trusting an in-memory `persisted?`, and does not rerun a callback that may have half-completed.

### Reviews say whether the decision saved

[`ProofReview`](../../app/models/proof_review.rb) records immutable decisions; the application's proof status records current state. Each intent has an application-scoped decision key and the reviewed document's blob ID, or an explicit missing-document target. The form preserves that key and target on validation failure. Under the application lock, the model returns an identical replay without repeating status changes, rejection counts, purges or follow-up; changed input with the same key is refused. A new decision gets a new key and retains earlier decisions. Rejected files can be purged without removing their historical identifiers. Decision history orders by `reviewed_at`, then row ID.

[`ProofReviewer`](../../app/services/applications/proof_reviewer.rb) and [`DisabilityCertificationReviewer`](../../app/services/applications/disability_certification_reviewer.rb) ask the same question when an error escapes a new review: did the decision commit? [`Applications::ReviewCommit`](../../app/services/applications/review_commit.rb) answers it from the exact keyed decision and application facts read before the writes, inside the transaction after them, and again after the error.

- Matching the in-transaction facts means the decision saved. The reviewer keeps it, reports a warning, and attempts a `proof_review_follow_up_failed` event.
- Matching the starting facts means it rolled back, and the original error propagates.
- Anything else raises `ReviewCommit::Unconfirmed`, and the admin is told to check the application before deciding again. That includes a failed read and a review that changed nothing, because an unchanged row cannot prove a commit.

An identical keyed replay is resolved before commit classification. It returns the recorded decision and does not automatically resend delivery; staff use the existing explicit request/resend actions when follow-up needs attention.

Inside a transaction the caller holds, such as certification rejection during paper intake, `ReviewCommit` gives no verdict. The caller owns the commit and decides what its own outcome means.

### Initial voucher issuance retries confirmed rollbacks

[`Vouchers::IssuanceService`](../../app/services/vouchers/issuance_service.rb) checks durable voucher state after an issuance error. [`IssueInitialVoucherJob`](../../app/jobs/issue_initial_voucher_job.rb) retries only `IssuanceService::RolledBackFailure`, which confirms that the issuance did not persist. Disabled vouchers, an existing voucher, and an ineligible application remain intentional no-ops.

A committed voucher with incomplete follow-up, or an issuance whose commit cannot be confirmed, creates an `initial_voucher_issuance_attention` audit and a record-only administrator notice. Staff must check voucher and delivery status before issuing another voucher. If attention recording fails, the job fails without automatic reissuance; its safe error context contains the application, voucher when known, job, and commit state for manual recovery. A non-admin initiating actor is preserved on the records, while the internal notice goes to the configured system audit administrator; a missing system actor also requires manual recovery.

## State, history, and delivery stay together

- Lifecycle changes go through [`Application#transition_status!`](../../app/models/application.rb) and [`#reconcile_workflow_state!`](../../app/models/concerns/application_status_management.rb); a raw status write skips history and follow-up.
- Proof-rejection audit and resubmission delivery are already coordinated by [`ProofDecisionFollowUp`](../../app/services/applications/proof_decision_follow_up.rb) and `RequestProofResubmission` — a second sender duplicates the notice.
- `NotificationService.create_and_deliver!` owns notification creation and the optional `audited` row flag. Its private `EmailDelivery::NotificationDispatch` adapts catalog arguments and records delivery routing/outcomes. The operation returns a notification or `nil`; `deliver: false` records without dispatch, and some actions are permanently record-only. Business audit events remain with their workflow owners ([notifications](../features/notifications.md)).
- `AuditEventService` writes events; [`EventDeduplicationService`](../../app/services/applications/event_deduplication_service.rb) only chooses what a timeline displays. Display deduplication does not make a write idempotent.
- Secure requests record their logical recipient, delivery owner, and source at issuance, through the recipient resolver and [issuance integrity service](../../app/services/applications/secure_request_issuance_integrity.rb). Historical forms missing that ownership cannot have it reconstructed from today's contact data.

Portal proof replacement uses `Application#proof_resubmittable_via_portal?` for both dashboard links and direct uploads. Submission-event counts do not impose another limit: the existing rejection policy warns at eight counted rejections and archives after the ninth, allowing a final correction at the warning threshold. Secure request forms retain their separate eligibility rule for missing as well as rejected proofs.

The duplicate review index pages matching name/date-of-birth groups, then pages exact comparisons within the selected group before loading users and building forms. [`DuplicateReconciliation::Population`](../../app/services/duplicate_reconciliation/population.rb) owns both those bounded queries and complete report population. Existing pair-state classification and locked review actions remain authoritative; pagination does not truncate exports or grant permission to act on a stale pair.

### Evaluation report state

[`Evaluations::SubmissionService`](../../app/services/evaluations/submission_service.rb) completes the report and records its audit event in the same transaction. Report lifecycle uses completed status, and `report_submitted_at` records when it was submitted, with unknown historical times left nullable.

The service locks the application before the evaluation and rechecks approval and the assigned actor. An assigned administrator can record outside-specialist consultation from requested, scheduled, or confirmed status with its actual completion time and written context, without inventing a planned appointment or trials. Direct reports retain their existing requirements. [EquipmentNeeds::Writer.initialize_from!](../../app/services/equipment_needs/writer.rb) participates in this transaction, initializing once without creating physical equipment. Confirmation delivery follows the saved report; an enqueue failure does not undo the report or needs.

### Training authority, reports, and delivery

[`Applications::TrainerAssignment`](../../app/services/applications/trainer_assignment.rb) owns assignment, reassignment and removal of the nullable `Application#assigned_trainer` reference. [`TrainingManagement`](../../app/models/concerns/training_management.rb) owns reserved capacity and latest-source eligibility for new work. Session `trainer_id` records authorship. Normal completion retains coverage; explicit administrative removal clears it even without an open appointment. `latest_training_follow_up_session` handles the latest cancelled/no-show source, while additional appointments require a completed source. Both use the application-level eligibility rule rather than treating any historical report as scheduling authority.

Named training commands acquire the application lock before the session lock and recheck the current actor/state after reload. They save the intended state and structural audit in the same transaction. A partial unique index allows one requested/scheduled/confirmed row per application. Completion/cancellation/no-show close existing work without applying new-appointment quota/window gates. Rescheduling records an explicit constituent-requested change to a different future agreement, including a change entered after the original start; a no-show remains a separate recorded outcome. The generic writable-status controller/service path has been removed.

[`CompleteService`](../../app/services/training_sessions/complete_service.rb) requires an actual `completed_at` between request creation and the present, trained product, duration, deliberately shared summary, and supported authored locale; it captures `report_submitted_at` on the server. Private `internal_notes` are retained when omitted and replaced/cleared only by an explicit submitted edit. The constituent history controller scopes completed sessions through `Application.accessible_by(current_user)` and reads only shared text. A former trainer's completed-report access is separate from current contact/preparation and mutation permission.

Command owners call [`TrainingSessionNotifier#deliver_after_commit`](../../app/services/training_session_notifier.rb) with actor, action, and date-change context. It captures public appointment facts and uses `ActiveRecord.after_all_transactions_commit`, then the existing `NotificationService`/mailer/letter catalog. There is no training model delivery callback. Its mutable outcome distinguishes deferred, queued, suppressed, and failed follow-up; a caught delivery exception records the error class and does not convert a committed operation into a failed save. Completion template variables exclude private notes, summary bodies, and outcome reasons. Seeds/migrations install missing localized completion templates without overwriting later administrator edits.

### Product evidence and public resources

[`Applications::ProductHistory`](../../app/queries/applications/product_history.rb) accepts an already-authorized Application relation and an explicit `fulfilled` or `portal_visible` mode. Portal dashboard/index/show and application details use the latter; trainer preparation uses fulfilled evidence. Both read qualifying completed voucher lines and active shipped equipment. Portal visibility adds sent direct units and allocated received stock. Unsent/bid-only/unallocated/withdrawn units grant no access. The reader groups by beneficiary and exact product, retaining per-unit/purchase-line source identity, quantity, derived status and optional shipment date. Guidance authorization and list inclusion share that owner; demo training uses its separately authorized session product.

[`ProductResource`](../../app/models/product_resource.rb) owns exact-product membership, supported content locale, title, and link/PDF exclusivity against intended attachment changes. [`WebUrlValidator`](../../app/validators/web_url_validator.rb) is shared with manufacturer documentation: absolute HTTP(S), a host, no credentials, whitespace/control characters, or non-web schemes. Links are navigation only; the server does not fetch or embed them. Localized guidance does not fall back to manufacturer metadata or device-type targeting.

The nested admin controller loads resources through their product, including archived products. The shared upload control stages the PDF and waits for a clean scan before submitting its signed receipt. [`ProductResources::Writer`](../../app/services/product_resources/writer.rb) accepts that receipt, locks the resource, and checks and locks the cleared blob through [`UploadedDocument`](../../app/services/uploaded_document.rb). It saves the resource, attachment change, and product audit event in one transaction. A validation failure keeps the staged file available for retry while the prior resource and file remain published. Scan jobs handle recovery and cleanup of unattached files. Replaced attachments purge after commit through Active Storage. Audit history records product/resource IDs, source type, and changed field names, survives resource deletion on the product, and excludes file bodies, signed references, and URLs.

The narrow `:product_resource` upload purpose accepts only detected PDFs, with an inclusive 10 MB limit; proof, certification, and W9 policies retain their existing limits/types. [`DocumentValidator`](../../app/validators/document_validator.rb) checks changed-attachment metadata, while the intake content inspector checks the PDF bytes. [`shared/product_resources`](../../app/views/shared/_product_resources.html.erb) provides exact-locale guidance, labeled alternatives, and public signed proxy downloads. Resource request/SQL filters hide URLs and upload references. Personalized application/device/session relationships stay behind their own controller authorization.

### Equipment purchasing

[EquipmentNeeds::Writer](../../app/services/equipment_needs/writer.rb) owns one-time report initialization, the retained source-evaluation FK and reasoned quantity/setup edits. The first explicit save stamps `equipment_needs_decided_at`, even when empty or unchanged; automatic initialization does not. Outside-catalog/no-suitable outcomes remain review work until that decision. Zero rows retain provenance. Needs contain remaining unmaterialized quantities; pre-award bid reservations are subsets of them, not additional units.

[Equipment::Bidding](../../app/services/equipment/bidding.rb) owns fixed mixed-model reservation sets and reasoned releases. [Equipment::Ordering](../../app/services/equipment/ordering.rb) awards all live lines in one transaction to a new or explicitly selected matching unsent PO, materializes new units, and relinks detached units. Staff send the PO outside the app; a separate command records that sent date. Bid/PO purpose and funding are single-valued. Global normalized PO identity replaces vendor-scoped procurement identity.

[Equipment::StockReceipt](../../app/services/equipment/stock_receipt.rb) receives existing purchased units or records verified existing-stock provenance. [Equipment::StockAllocation](../../app/services/equipment/stock_allocation.rb) owns FIFO exact-model allocation, release/restoration, detached replacement and same-model swaps. EquipmentItem's immutable acquisition source, original PO and acquisition line identify the physical unit through onward allocation. Stock counts derive from received/allocation/shipment facts. [Equipment::Shipment](../../app/services/equipment/shipment.rb) checks one beneficiary/destination/source, dates, tracking, physical identifiers and stock setup confirmation. Receipt/allocation does not record shipment.

[Equipment::Mutation](../../app/services/equipment/mutation.rb) supplies admin authorization, procurement eligibility, versions, application locks and audit operations. Writers revalidate membership under sorted application/need/bid/PO/item locks, keeping validated writes and audit rows in one transaction. Award and stock allocation also require the complete reviewed application-revision map, derived from `updated_at` for stale-form detection. An explicit read-only shipping/setup refresh retains draft inputs; saving compares the map under application locks before snapshots. Operational wait clocks continue to use their dedicated domain dates. Models and database constraints enforce row-local source/relationship and identity invariants. [Equipment::Correction](../../app/services/equipment/correction.rb) owns reasoned factual corrections; reserved work and stock allocation must be resolved at their owners first. Historical records survive withdrawal, cancellation and archival.

[Equipment::FulfillmentStage](../../app/models/equipment/fulfillment_stage.rb) reads one primary application stage plus secondary outstanding quantities and waits. Application badges and [ApprovedPipeline](../../app/models/applications/approved_pipeline.rb) delegate to it. EquipmentItem owns raw source/order/receipt/shipment predicates. Operational clocks use durable domain fields rather than scanning equipment Events or unrelated `updated_at`; unknown clocks remain unknown. Equipment queues show eligible units independently of their application's primary card.

[Equipment::SupplierList](../../app/presenters/equipment/supplier_list.rb) presents current active PO membership or explicitly scoped internal dispatch units with shared five-field content. Stock supplier lists read original acquisition-line setup and PO receiving address; dispatch reads onward snapshots. The shared list partial renders the supplier table and a native details disclosure with readonly plain text; it has no clipboard JavaScript. The separate device-record partial labels PO and application contexts explicitly and shows per-device shipment, identifiers and correction history. Shipping snapshots use the shared encrypted [EquipmentShipping](../../app/models/concerns/equipment_shipping.rb) field contract; parameter and audit privacy protect those names, including shipping state.

[Equipment::RequestParameters](../../app/services/equipment/request_parameters.rb) validates internal return context. The unpaginated request form retains native checked controls while local filters hide rows; `Equipment::Queue#selection` resolves explicit IDs against the authorized tab-wide scope. Display filters grant no authority. Correction previews use the existing Turbo/form owner and recheck confirmed impact before saving.

[Equipment::PurchaseCosts](../../app/services/equipment/purchase_costs.rb) records optional actual per-unit PO costs independently of Product MSRP, with reviewed membership/versions and existing filed-invoice protections.

**Equipment by Type** reads active units by actual outbound `shipped_at` across all acquisition sources, including existing stock without a PO. It does not use procurement dates, receipts or allocations as distribution. Carrier links use allowlisted official HTTPS destinations and encoded tracking numbers; the server performs no carrier synchronization. [Equipment::AuditRecords](../../app/queries/equipment/audit_records.rb) batches historical labels for protected Event changes; audit history remains separate from operational stage clocks.

### iCanConnect

The normal application and proof review establishes eligibility. Devices, assessments and training sessions record their own MAT or iCanConnect funding, so one application can receive both. [`Icanconnect::FilingPrep`](../../app/services/icanconnect/filing_prep.rb) gathers device and service costs, including training dates, billable hours and linked devices. [`Icanconnect::FilingWriter`](../../app/services/icanconnect/filing_writer.rb) owns locked financial evidence changes, exact-row filing marks and reasoned corrections; export readers recheck private attachment access and clearance. See the [operating guide](../operations/icanconnect.md) for cost recording and external filing boundaries.

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

[`Current`](../../app/models/current.rb) carries the actor and short-lived workflow state. The flags have different consumers, and a flag's name doesn't tell you what it bypasses.

| Attribute | Actual effect |
| --- | --- |
| `paper_context` | Paper intake relaxes selected profile validations, and `ProofAttachmentService` leaves reconciliation and delivery to the intake. It does not change whether a proof validation runs. Set and restored by the owning service or controller. |
| `force_notifications` | Declared but unused by production delivery paths. |
| `user` | Request-scoped audit actor resolved from the persisted signed-cookie session. Unit tests may supply an actor explicitly; it is not an authentication input. |

Proof review markers are derived before the application saves: attached required proofs with `not_reviewed` status in an open application need review; reviewed proofs do not. A submission updates the marker and the final review clears it in the same save. The attachment service no longer needs a context flag to suppress a second timestamp save, and a completed evaluation does not clear proof work.

The readers are in [`ProofManageable`](../../app/models/concerns/proof_manageable.rb), [`Authentication`](../../app/controllers/concerns/authentication.rb), [`UserProfile`](../../app/models/concerns/user_profile.rb), [`Users::Constituent`](../../app/models/users/constituent.rb), and [`ProofAttachmentService`](../../app/services/proof_attachment_service.rb). Temporary state is restored through block scope or `ensure`; paper context in particular is not a way to suppress validations, audit events, or notifications. Training commands explicitly schedule delivery through `TrainingSessionNotifier` after commit.

## Tests

Service tests for the operation's result and side effects, controller or integration tests for the real caller. Attachment persistence needs the real attachment service rather than a mock.

- [Paper application service](../../test/services/applications/paper_application_service_test.rb) — creation, rollback, follow-up warnings.
- [Proof attachment service](../../test/services/proof_attachment_service_test.rb) — files, status, events.
- [Notification service](../../test/services/notification_service_test.rb) — record creation versus delivery.
- [Duplicate-merge concurrency](../../test/services/users/duplicate_merge_service_concurrency_test.rb) — competing writes at the lock boundary.
