# MAT Vulcan TODOs

This document lists only remaining work. Tasks are small, explicit, and testable. Control IDs in brackets map to `docs/security/controls.yaml`.

## Table of Contents

- [Encryption startup validation](#encryption-startup-validation)
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

## Encryption startup validation

The [encryption initializer](../../config/initializers/active_record_encryption.rb) now rejects absent, missing, and blank production key settings. The [Docker asset build](../../Dockerfile) permits process-local temporary keys only when `SECRET_KEY_BASE_DUMMY=1` and the sole top-level Rake task is `assets:precompile`. [Guard tests](../../test/config/encryption_key_configuration_test.rb) cover that exception and reject dummy-key runtime and database tasks.

- [ ] Add isolated boot coverage for configured startup with an existing encrypted-value round trip and the development/test fallback, using generated material without production credentials or database access.
- [ ] Exercise the Docker asset build in its deployment environment and verify that server, worker, console, and release startup require persistent keys in the resulting image.
- [ ] Verify restored encrypted data with the configured keys using the [recovery guide](../infrastructure/backup_and_recovery.md). A presence check cannot establish that supplied keys match a restored database.

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
- [ ] Extract shared validation utils and document usage (README in controllers/)
- [ ] CI wiring: ensure lint + JS tests run; document scripts in package.json  [SCA-001][PATCH-001]

Income threshold (FPL) validation follow-ups
- [ ] Check for unit tests for `app/javascript/services/income_threshold.js` (threshold and `exceeds`) with parity to server `IncomeThresholdCalculationService` for sizes 1–8.  If no test exist write them.  If tests exist make sure they provide appropriate coverage and all pass. [TEST-001]
- [ ] Standardize tests to target `[data-income-validation-target="warningContainer"]` and use `[hidden]` for visibility checks; avoid relying on CSS-only classes.  [TEST-001]
- [ ] Confirm no dual ownership: remove any `data-paper-application-target="incomeThresholdWarning"` or warning toggling from non-owner controllers.  [PATCH-001]
- [ ] Grep for `#income-threshold-warning` usages in admin paths and replace with `#admin-income-threshold-warning` or target-based selectors as appropriate.  [PATCH-001]

Paper guardian/dependent identity-review follow-ups
- [ ] Make guardian identity-choice actions single-flight. Disable every rendered "Use this guardian"
      action and the different-person override while one choice request is pending, ignore repeated
      activation, and restore the actions after a safe refusal. Pin the double-activation behavior in
      `user_search_controller_test.js`, including the override case where the first request may
      already have committed before its browser response is canceled. [TEST-001][DATA-002]
- [ ] Associate an `invalid_contact_choice` refusal with the dependent contact field that must be
      corrected. Keep the existing visible panel, live-region announcement, focus, and `aria-invalid`;
      add an `aria-describedby` reference to stable refusal text and remove it when review state is
      cleared. Cover both dependent email and phone, plus cleanup after correction. [TEST-001]

## Registration & Account Integrity  [DATA-001][DATA-002][AUTHZ-002][AUDIT-002]

Customer import — post-import reconciliation  [DATA-001][DATA-002]

- [ ] Run the documented read-only production duplicate-review inventory grouped by source/status. *(Development inventory was empty, which does not prove production zero. Historical `paper_intake` and `admin_create` rows remain historical and are not post-import suppression state.)*

Signed-in portal locale routing  [DATA-002]

- [ ] Constituent-facing portal pages render in `I18n.default_locale` for signed-in users regardless
  of `users.locale`. `I18n.with_locale` is applied only in public auth flows
  (`ApplicationController#with_public_request_locale`), so nothing routes a signed-in guardian to the
  Spanish strings that already exist for their pages. Decide whether the portal should follow the
  account locale, a request parameter, or both, then apply it once rather than per-controller.
  Surfaced while adding `constituent_portal.dependents.*`: the `es` entries are correct and
  unreachable.

MFA enrollment localization

- [ ] Apply the signed-in locale policy above to constituent-facing MFA setup and credential
  enrollment. Translate the setup screens, WebAuthn/TOTP/SMS enrollment feedback in `auth.js`,
  and the pending SMS enrollment service's duplicate-send message. Cover setup, validation
  failures, retry, and completion for each factor in English and Spanish with system tests.
  Keep public sign-in and MFA verification language tied to the request, not the matched account.

## Notification System

Analytics  [AUDIT-001][DATA-001]
- [ ] Decide on event schema/storage (extend `events` vs. dedicated table/topic) + retention policy  [AUDIT-001]
- [ ] Migration: add analytics table or extend `events` with fields (template, channel, outcome)  [AUDIT-001]
- [ ] Instrument: email, in-app, fax senders to emit analytics events  [AUDIT-001]
- [ ] Dashboard: admin page with metrics (send/open/click/bounce/time-to-action)
- [ ] Toggle: simple A/B or throttling flag per template
- [ ] Tests: event emission, dashboard queries, permission checks

Admin notices for recurring jobs  [AUDIT-001]
- [ ] Decide whether admins need an "invoice ready for review" notice and an expired-voucher report. Invoice generation and voucher expiration called a nonexistent `AdminNotificationsMailer`; those calls were removed. Building them needs a mailer, EN templates, and catalog entries.

Bounce/complaint webhook  [AUDIT-001]
- [ ] Deploy the attempt-based delivery feedback implementation and configure authenticated outbound webhooks after following the [Postmark rollout runbook](../infrastructure/postmark_delivery_visibility.md). The route no longer depends on `MedicalProviderEmail`; production stream configuration remains an operations step.

Certification queue visibility  [DATA-001]
- [ ] DCF escalation no longer requests certification automatically. Consider an admin filter for applications that are `awaiting_dcf` with certification Not Requested.

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

Guardian selected pane fails WCAG 1.4.10 Reflow at 320 CSS pixels
- [ ] `#guardian-info-section` renders 364px wide at a 320px viewport, overflowing the document by
      60px and forcing horizontal scrolling to read. Measured on `/admin/paper_applications/new`
      with a guardian selected. The bare page is clean (`scrollWidth == clientWidth == 320`); the
      overflow appears only once the selected pane renders, so the pane's own layout is the
      suspect, not the page shell.
- [ ] Inventory every surface that renders the guardian selected pane before fixing — the paper
      intake form is where it was found, not necessarily the only place it appears.
- [ ] Reflow conformance is a whole-page property, so this failure is the page's regardless of
      which component causes it. The adjacent existing-dependent summary was measured at the same
      width and does not contribute (238px, no inner overflow); see the 320px assertion in
      `test/system/admin/paper_application_rollback_test.rb`.
- [ ] Note 320 CSS px ≡ 400% zoom from a 1280px viewport. A 375–390px phone capture is useful
      mobile evidence but is not this claim, and a 200% text check addresses 1.4.4 Resize Text
      rather than Reflow.

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

Production Bucketeer direct uploads  [FILE-SEC-001]
- [ ] Verify a nonsensitive file uploads through a browser form on dev and production, persists as an attachment, and reopens through the application; a server-side upload does not prove browser CORS.

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
- [ ] UI: read/write `Proof` records
- [ ] Audit/events: include `proof_id` and `kind`  [AUDIT-002]
- [ ] Tests: backfill correctness, services, UI reads

## Why “MAT Vulcan”?

MAT stands for Maryland Accessible Telecommunications. Vulcan is the Roman god of the forge—a maker of equipment. Since MAT helps people get accessible telecommunications equipment, the name is a playful nod to that connection. A little mythology, a little wordplay; no relation to the Vulcans from Star Trek.

“Vulcan” is an internal nickname. Public-facing pages and messages use Maryland Accessible Telecommunications. Internal module, database, deployment, and synthetic-email identifiers retain their existing names; they are not display labels. The existing TOTP issuer also remains `MatVulcan`.

### Fax-provider replacement

Fax sending is explicitly unavailable because the installed Twilio SDK has no fax API. Choose and verify a replacement provider before re-enabling this transport. Retain All/category enforcement, original attempt authorization, exact SID callback identity, idempotent fallback and media ownership. Historical signed callbacks remain supported; no automatic replay of legacy or canceled attempts.
