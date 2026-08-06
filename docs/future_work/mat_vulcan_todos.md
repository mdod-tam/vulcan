# MAT Vulcan TODOs

This document lists only remaining work. Tasks are small, explicit, and testable. Control IDs in brackets map to `docs/security/controls.yaml`.

## Table of Contents
- [Application & Dependent Contact Management](#application--dependent-contact-management)
- [JavaScript Architecture & Frontend Tests](#javascript-architecture--frontend-tests)
- [Registration & Account Integrity](#registration--account-integrity)
- [Notification System](#notification-system)
- [Communication & Feedback](#communication--feedback)
- [UI/UX Enhancements](#uiux-enhancements)
- [Advanced Reporting](#advanced-reporting)
- [System Integrations](#system-integrations)
- [Audit & Event Tracking](#audit--event-tracking)
- [Proofs, Statuses, Templates (Tech Debt)](#proofs-statuses-templates-tech-debt)
- [Mobile Proofs Workflow](#mobile-proofs-workflow)
- [Optional / Larger Architectural Work](#optional--larger-architectural-work)

## Application & Dependent Contact Management  [DATA-001][DATA-002][AUTHZ-002][AUDIT-002]

- [ ] Decide data model for contact strategies (user columns vs. `UserGuardianship` fields)  [DATA-001]
- [ ] Migration: add `email_strategy` and `phone_strategy` enums (with default and null constraints)  [DATA-001]
- [ ] Backfill: rake task to set default strategy for existing dependents  [DATA-001]
- [ ] Model: implement `has_own_contact_info?` and `uses_guardian_contact_info?`  [DATA-002]
- [ ] Validations: enforce uniqueness/format based on chosen strategy  [DATA-002]
- [ ] Forms: expose strategy choice in dependent creation/edit
- [ ] Paper forms: update labels/help text clarifying source of contact
- [ ] Admin: surface and allow override of strategies on dependent profile  [AUTHZ-002]
- [ ] Tests: model (strategy logic), controller (update/create), system (guardian vs self)  [AUDIT-002]

## JavaScript Architecture & Frontend Tests  [TEST-001][SCA-001][PATCH-001]

- [ ] Choose JS test runner setup (Node + jsdom vs. headless browser) and mocking approach  [TEST-001]
- [ ] rails_request.js tests: success (200 JSON), success (HTML), failure (4xx/5xx), network error, retry path  [TEST-001]
- [ ] BaseFormController tests: field validation, error summary rendering, focus management  [TEST-001]
- [ ] Autosave controller tests: debounce, pending/saved states, error state  [TEST-001]
- [ ] Upload controller tests: file type/size validation, progress, error/retry  [TEST-001]
- [ ] Extract shared validation utils and document usage (README in controllers/)
- [ ] CI wiring: ensure lint + JS tests run; document scripts in package.json  [SCA-001][PATCH-001]

Income threshold (FPL) validation follow-ups
- [ ] Check for unit tests for `app/javascript/services/income_threshold.js` (threshold and `exceeds`) with parity to server `IncomeThresholdCalculationService` for sizes 1–8.  If no test exist write them.  If tests exist make sure they provide appropriate coverage and all pass. [TEST-001]
- [ ] Standardize tests to target `[data-income-validation-target="warningContainer"]` and use `[hidden]` for visibility checks; avoid relying on CSS-only classes.  [TEST-001]
- [ ] Confirm no dual ownership: remove any `data-paper-application-target="incomeThresholdWarning"` or warning toggling from non-owner controllers.  [PATCH-001]
- [ ] Grep for `#income-threshold-warning` usages in admin paths and replace with `#admin-income-threshold-warning` or target-based selectors as appropriate.  [PATCH-001]

## Registration & Account Integrity  [DATA-001][DATA-002][AUTHZ-002][AUDIT-002]

Duplicate-review outcome contract  [AUTHZ-002][AUDIT-002]

The determination half of the matrix is **decided and enforced**: `ResolutionService` accepts no determination and always records `keep_separate`, so no other outcome can close a case. What remains is the *action* half — `approve` and `ignore` are still selectable and still written to `resolution_action` — plus the external-consumer inventory that gates retiring them.

- [x] Define the complete allowed action/determination matrix. Each outcome needs two separate answers: is it terminal, and if terminal does it release the submission gate. *(Decided; the determination half is enforced — `keep_separate` is the only outcome `ResolutionService` records, and it is server-owned.)*
- [ ] **Retire the `approve`/`ignore` actions and their UI together (5c-2).** *(Unblocked — the consumer inventory came back clean.)* Remove the action fieldset, stop accepting `resolution_action` from the request, update the surrounding copy, and preserve historical values. These must land as one change: backend-first leaves Approve and Ignore visible while the server rejects them; UI-first changes which action values are newly written. Three constraints on the implementation:
  - **Do not derive replacement metadata.** With no consumer, stop writing `resolution_action` outright rather than emitting a value nobody reads. Do not add a compatibility writer "just in case" — one without an explicit removal condition becomes permanent by default.
  - **Reject a stale `resolution_action` without mutation.** After the fieldset disappears, a page rendered before deployment can still submit `approve` or `ignore`. Silently reinterpreting either as keep-separate repeats exactly the failure the existing `determination` rollover guard exists to prevent. An absent value proceeds.
  - **Keep `Admin::DuplicateReviewsHelper::STATUS_LABELS`.** It maps `resolved_approved` to "Approved" and is the only in-repo reader distinguishing the two resolved statuses. It will look like dead code once the writer is gone; deleting it blanks the status badge on historical cases.
- [x] **Was blocking 5c-2:** verify — do not assume — whether any external consumer reads `status` or `resolution_action`. *(Answered: **there are no external consumers**. The in-repo half was swept and found `resolution_action` write-only, with no reader in reports, exports, rake tasks, JSON payloads, audit-log display, webhooks, or database views; the out-of-repo half — BI exports, warehouse queries, scheduled reports, manual operational SQL — was confirmed empty. **No compatibility window is needed**: 5c-2 stops writing `resolution_action` outright and does not derive a replacement value. Revisit only if reporting is built against these fields before 5c-2 ships.)*
- [x] Decide whether `same_person_confirmed` may terminate a case without the merge that conclusion implies. *(No — reserved to the merge service, written atomically with it; enforced.)*
- [x] Decide whether `fraud_or_security_review` is terminal, and whether it releases submission. *(Non-terminal — no security-review queue or handoff owner exists, so closing removes the case from the only queue there is; enforced.)*
- [x] Decide whether `authorized_relationship_confirmed` is terminal. *(No — non-terminal, and enforced as such: `ResolutionService` records only `keep_separate`, so the value cannot close a case.)* **Enabling** it later is separate work blocked on a structural gap, not a pending decision: the service receives no selected candidate, so it needs a candidate/pair identifier in the resolution contract plus an exact verified `GuardianRelationship`, never created as a side effect. `guardian_relationships` has no active/revoked state.
- [x] Decide whether the `approve` and `ignore` actions carry operational or reporting meaning. *(Retire both; the determination holds the durable semantics. Retirement itself is 5c-2 above.)*
- [x] Preserve historical values, and inventory cases already resolved with a combination the matrix disallows. *(No remediation set exists: no datastore holds real duplicate-review resolution history, so the inventory would return only seed artifacts. Nothing was reopened or re-blocked. This becomes live again if the customer import lands — see below.)*
- [x] Add one behavioral test per final outcome asserting its gate result, replacing constant-shaped assertions with matrix-driven coverage. *(`NON_TERMINAL_DETERMINATIONS` was removed entirely, so no constant-shaped assertion remains. Coverage for `authorized_relationship_confirmed` succeeding stays untestable until that outcome is enabled.)*
- [x] Decide the guardian-authority policy. *(**Ratified**: the gate follows the applicant and never the acting guardian. A guardian with their own open case may still submit for a dependent, because the guardian's unresolved identity question does not put the dependent's identity in doubt and blocking would penalize a dependent whose record was never in question. Documented in [Current Application Features](../current_application_features.md) and pinned by tests in `test/services/applications/application_creator_test.rb`.)*

Customer import — decide before building  [DATA-001][DATA-002]

- [ ] Before building the customer importer, decide whether reconciliation creates duplicate-review cases and, if so, define its `source`, its submission-gate consequence, queue ownership, throughput, and audit behavior. An importer opening `registration_soft_match` cases blocks every matched imported constituent from final submission; any other source blocks nobody but flags the whole imported population. No importer exists today, and this is general-purpose identity reconciliation, which sits outside the Contact Foundation epic's boundary.

Portal dependent duplicate-submission idempotency  [DATA-002]
- [ ] Re-run `DuplicateDetectionService` inside the guardian lock in `ConstituentPortal::DependentsController#create`. Detection runs before the lock and is never re-checked, so two identical submissions can both clear it and create two dependents. Nothing downstream catches the second: under the guardian contact strategy each dependent gets its own unique synthetic email and phone, so no unique index fires, and `guardian_relationships` is unique on `(guardian_id, dependent_id)`, which differs.
- [ ] Add submit-disable to `app/views/constituent_portal/dependents/_form.html.erb` to kill the common double-click trigger; the form has no `disable_with` today.
- [ ] Tests: two identical submissions create exactly one dependent, and the second is refused with no side effects.

Notes: predates the PR4d atomicity work and is unchanged by it, but PR4d added the guardian lock that makes the first item possible. Cleanup is expensive today because duplicates created this way cannot be merged through the admin merge UI, which accepts only `registration_soft_match` cases.

## Notification System

Analytics  [AUDIT-001][DATA-001]
- [ ] Decide on event schema/storage (extend `events` vs. dedicated table/topic) + retention policy  [AUDIT-001]
- [ ] Migration: add analytics table or extend `events` with fields (template, channel, outcome)  [AUDIT-001]
- [ ] Instrument: email, in-app, fax senders to emit analytics events  [AUDIT-001]
- [ ] Dashboard: admin page with metrics (send/open/click/bounce/time-to-action)
- [ ] Toggle: simple A/B or throttling flag per template
- [ ] Tests: event emission, dashboard queries, permission checks

SMS alignment  [DATA-001][DATA-002][AUTHZ-003]
- [ ] Decide scope (email + 2FA-SMS only vs. general SMS)
- [ ] If general SMS: implement `SmsService` (provider client, rate limit, consent)  [AUTHZ-003]
- [ ] Templates: add SMS templates + preview in admin  [DATA-002]
- [ ] Status UI: delivery/bounce states  [AUDIT-001]
- [ ] Docs/admin copy: update to reflect chosen scope  [DATA-001]

## Communication & Feedback  [DATA-002][AUDIT-001]

- [ ] Finalize triage destination (email vs. vendor) + PII redaction policy  [DATA-002]
- [ ] UI: add "Report an issue" link to high-friction pages (application, uploads)
- [ ] Endpoint: `ReportsController#create` with context payload
- [ ] Delivery: send to triage destination (mailer or vendor API)
- [ ] Live chat spike: compare 2–3 options (capabilities, cost, security); write brief  [DATA-001]
- [ ] Live chat MVP: feature flag, embed, transcript capture to audit events  [AUDIT-001]
- [ ] Tests: controller create, mail delivery, feature-flag behavior

## UI/UX Enhancements

- [ ] Tooltip/inline-help component: Stimulus controller + Tailwind styles
- [ ] Data API: `data-help` attributes on inputs; ARIA compliance
- [ ] Seed initial help copy for income/residency/medical fields (i18n YAML)
- [ ] Track interactions (open/close) to inform copy improvements

## Advanced Reporting  [DATA-001][DATA-002][AUTHZ-002][AUDIT-002]

Custom report builder
- [ ] Determine query builder pattern we want to use (AREL/services), field whitelist, export boundaries  [DATA-002]
- [ ] Define v1 use-cases and field/filter list (doc)
- [ ] Service: `ReportQueryBuilder` with whitelisted filters/sorts  [DATA-002]
- [ ] Controller/routes: `/admin/custom_reports`  [AUTHZ-002]
- [ ] UI: filters form, pagination, saved queries
- [ ] Export: CSV pipeline (background job + signed URL download)
- [ ] Permissions: restrict by role; audit export actions  [AUTHZ-002][AUDIT-002]
- [ ] Tests: query service, controller, CSV export job

Data privacy compliance  [DATA-001][DATA-002]
- [ ] Review current reports vs. privacy policy/security controls
- [ ] Mask/omit sensitive PII in exports; add regression tests

## System Integrations

Medical certification document signing  [DATA-001][AUTHZ-003][AUDIT-001]
- [ ] Docuseal artifact storage plan  [DATA-001]
- [ ] Prototype: send signing request, receive webhook, verify signature  [AUTHZ-003]
- [ ] Secrets: configure provider keys; secure storage  [DATA-001]
- [ ] Storage: signed document to S3 with encryption + retention policy  [DATA-001]
- [ ] Audit: log send/complete events; error handling + retries  [AUDIT-001]
- [ ] Tests: webhook verification, failure paths

Inbound fax processing (Twilio)  [DATA-001][FILE-SEC-001][AUTHZ-003][AUDIT-001]
- [ ] Mapping model for provider↔fax numbers; media lifecycle and trust  [DATA-001]
- [ ] Route: POST `/webhooks/twilio/fax_received`
- [ ] Controller: verify Twilio signature; parse payload  [AUTHZ-003]
- [ ] Service: download media, virus-scan, attach to application by mapping  [FILE-SEC-001]
- [ ] S3: upload outbound media; replace file:// URLs  [DATA-001]
- [ ] Admin UI: surface inbound fax events on application
- [ ] Tests: webhook, processor, integration

## Audit & Event Tracking  [AUDIT-001][AUDIT-002]

- [ ] Event browsing query shape + required DB indexes  [AUDIT-001]
- [ ] Controller: `Admin::EventsController#index` (filters, pagination)  [AUDIT-001]
- [ ] CSV export: service + controller action (scoped to filters)  [AUDIT-002]
- [ ] Rake: `audit:check` (missing creation events, orphaned events)  [AUDIT-002]
- [ ] Migrations: indexes on `events.action`, `events.created_at`, `(auditable_type, auditable_id, action)`  [AUDIT-001]
- [ ] Apply `Applications::EventService` to guardian/dependent flows consistently  [AUDIT-002]
- [ ] Tests: controller filters, CSV, rake task

## Proofs, Statuses, Templates (Tech Debt)  [FILE-SEC-001][DATA-001]

- [ ] Enum centralization location and JSON vs. normalized schema for complex metadata
- [ ] Module: centralize proof types in shared module
- [ ] Migration: add JSON column for extended proof/status metadata (if chosen)  [DATA-001]
- [ ] Refactor: use centralized enums; update references
- [ ] Templates: standardize under `NotificationComposer` and remove one-offs
- [ ] Tests: enum usage, JSON accessors (if applicable)

## Mobile Proofs Workflow  [FILE-SEC-001][DATA-002]

- [ ] Performance: measure upload timings; set target budgets
- [ ] Validation: client-side file size/type checks; user guidance copy  [FILE-SEC-001][DATA-002]
- [ ] Reliability: retry/backoff strategy; resumable upload spike
- [ ] Error UX: inline errors + resume flow
- [ ] Tests: upload error/retry paths on mobile viewport

## Optional / Larger Architectural Work

AASM state machine for `Application`  [AUDIT-002]
- [ ] Enum↔AASM mapping, transition callbacks, rollout plan
- [ ] Add gem; wire AASM column to existing enum
- [ ] Define states/events; move side effects to transition callbacks  [AUDIT-002]
- [ ] Replace direct status writes with events (temp shim + migration of call sites)
- [ ] Concurrency controls (`with_lock`) + transition audit trail  [AUDIT-002]
- [ ] Tests: unit for transitions/guards/callbacks; system updates

Consolidated `Proof` model  [FILE-SEC-001][DATA-001][AUDIT-002]
- [ ] Single table vs. polymorphic; FK strategy; migration plan
- [ ] Migration: create `proofs` + backfill rake task  [DATA-001]
- [ ] Services: update `ProofAttachmentService`/`ProofReviewService` for `Proof`  [FILE-SEC-001]
- [ ] UI/mailboxes: read/write `Proof` records
- [ ] Audit/events: include `proof_id` and `kind`  [AUDIT-002]
- [ ] Tests: backfill correctness, services, UI reads
