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

- [ ] Duplicate detection approach (heuristics vs. AI-assisted) and privacy constraints  [DATA-001][DATA-002]
- [ ] Signals: implement deterministic checks (email/phone/dob/address similarity)  [DATA-002]
- [ ] Service: `DuplicateDetectionService` returning matched score + reasons
- [ ] DB indexes to support queries (e.g., lower(email), phone digits only)
- [ ] UI: badge + table filter for `needs_duplicate_review`  [AUTHZ-002]
- [ ] Review queue: list, detail, actions (approve/merge/ignore) with rationale textarea  [AUTHZ-002]
- [ ] Merge semantics: pick canonical user/application; record merge event  [AUDIT-002]
- [ ] Tests: service scoring, controller actions, system flow with merge/ignore

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
