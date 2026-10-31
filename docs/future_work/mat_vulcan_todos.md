# MAT Vulcan TODOs

Work that's still open. Each item is small enough to build and test on its own.

## Table of Contents

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

## JavaScript Architecture & Frontend Tests

- [ ] Extract shared validation utils and document how to use them (a README in `controllers/`).
- [ ] Run the Jest suite in CI. `ci.yml` runs Brakeman, RuboCop, and `bin/rails test:all`, and nothing runs `yarn test`.

Income threshold (FPL) validation follow-ups
- [ ] Add unit tests for `calculateThreshold` and `exceeds` in `app/javascript/services/income_threshold.js`, checking household sizes 1–8 against `IncomeThresholdCalculationService`.
- [ ] Have the constituent-portal system tests find the warning through `[data-income-validation-target="warningContainer"]` and check the `hidden` attribute. `income_threshold_system_test.rb` still selects `#income-threshold-warning` and its `.hidden` class.

Paper guardian/dependent identity-review follow-ups
- [ ] Make guardian identity-choice actions single-flight. Disable every rendered "Use this guardian"
      action and the different-person override while one choice request is pending, ignore repeated
      activation, and restore the actions after a safe refusal. Pin the double-activation behavior in
      `user_search_controller_test.js`, including the override case where the first request may
      already have committed before its browser response is canceled.
- [ ] Associate an `invalid_contact_choice` refusal with the dependent contact field that must be
      corrected. Keep the existing visible panel, live-region announcement, focus, and `aria-invalid`;
      add an `aria-describedby` reference to stable refusal text and remove it when review state is
      cleared. Cover both dependent email and phone, plus cleanup after correction.

## Registration & Account Integrity

Customer import — post-import reconciliation

- [ ] Run the read-only duplicate-review inventory grouped by source and status.

Signed-in portal locale routing

- [ ] Some constituent pages follow the signed-in user's language and the rest don't.
  `ViewerLocale#with_viewer_locale` uses `params[:locale]`, then the account's message locale. The
  dashboard, products, training sessions, and `request_training` use it. Dependents, proof
  resubmission, and the other application actions still render in `I18n.default_locale`, so their
  Spanish strings can't be reached. Apply the policy in one place instead of controller by controller.

MFA enrollment localization

- [ ] Apply the viewer-locale policy above to constituent-facing MFA setup and credential
  enrollment. Translate the setup screens, WebAuthn/TOTP/SMS enrollment feedback in `auth.js`,
  and the pending SMS enrollment service's duplicate-send message. Cover setup, validation
  failures, retry, and completion for each factor in English and Spanish with system tests.
  Keep public sign-in and MFA verification language tied to the request, not the matched account.

## Notification System

Analytics
- Delivery attempts, receipts, and bounce feedback already live in `email_delivery_attempts` and `email_delivery_receipts`. What's left is reporting on them.
- [ ] Dashboard: an admin page with send, delivery, open, bounce, and time-to-action metrics.
- [ ] Toggle: a simple A/B or throttling flag per template.
- [ ] Tests: dashboard queries and permission checks.

Admin notices for recurring jobs
- [ ] Decide whether admins need an "invoice ready for review" notice and an expired-voucher report. Add the mailer, English templates, and catalog entries if needed.

Bounce/complaint webhook
- [ ] Configure authenticated outbound webhooks and the production Postmark stream using the [Postmark runbook](../infrastructure/postmark_delivery_visibility.md).

Certification queue visibility
- [ ] Add an admin filter for `awaiting_dcf` applications whose certification is Not Requested. The existing `awaiting_disability_certification` filter includes every `awaiting_dcf` application.

SMS alignment
- Texts go out through `SmsService` for account recovery, proof resubmission, and provider-info requests. They use no admin-editable templates.
- [ ] Templates: add SMS templates and an admin preview.
- [ ] Status UI: show delivery and bounce states.
- [ ] Before texting beyond those workflows, add per-recipient consent and rate limits.

## Communication & Feedback

- [ ] Finalize the triage destination (email vs. vendor) and a PII redaction policy.
- [ ] UI: add a "Report an issue" link to high-friction pages (application, uploads).
- [ ] Endpoint: `ReportsController#create` with a context payload.
- [ ] Delivery: send to the triage destination (mailer or vendor API).
- [ ] Live chat spike: compare 2–3 options (capabilities, cost, security) and write a brief.
- [ ] Live chat MVP: feature flag, embed, transcript capture to audit events.
- [ ] Tests: controller create, mail delivery, feature-flag behavior.

## UI/UX Enhancements

Guardian selected pane overflows at 320 CSS pixels (WCAG 1.4.10 Reflow)
- [ ] `#guardian-info-section` renders 364px wide at a 320px viewport and pushes the page 60px past
      the edge, so readers have to scroll sideways. It shows up on `/admin/paper_applications/new`
      once a guardian is selected; the page is clean (`scrollWidth == clientWidth == 320`) until the
      pane renders. The existing-dependent summary measures 238px with no inner overflow (see the
      320px assertion in `test/system/admin/paper_application_rollback_test.rb`), so the guardian
      pane is the one to fix.
- [ ] Find every surface that renders the guardian selected pane before fixing. The paper intake
      form is where it turned up, not necessarily the only place.
- [ ] Verify at 320px, which equals 400% zoom on a 1280px-wide window. A 375–390px phone capture
      or a 200% text-size check doesn't test Reflow.

Inline help
- [ ] Tooltip/inline-help component: Stimulus controller + Tailwind styles.
- [ ] Data API: `data-help` attributes on inputs, with ARIA support.
- [ ] Seed initial help copy for income, residency, and disability certification fields (i18n YAML).
- [ ] Track opens and closes to find the copy that needs work.

## Advanced Reporting

Custom report builder
- [ ] Pick the query builder pattern (Arel or services), the field whitelist, and export boundaries.
- [ ] Define v1 use cases and the field/filter list (doc).
- [ ] Service: `ReportQueryBuilder` with whitelisted filters and sorts.
- [ ] Controller/routes: `/admin/custom_reports`.
- [ ] UI: filters form, pagination, saved queries.
- [ ] Export: CSV pipeline (background job + signed URL download).
- [ ] Permissions: restrict by role and audit export actions.
- [ ] Tests: query service, controller, CSV export job.

Data privacy compliance

- [ ] Review current reports against the privacy policy and security controls.
- [ ] Mask or omit sensitive PII in exports, and add regression tests.

## System Integrations

DocuSeal go-live requirements
- [ ] Supply the configured signing template in the submission API payload and verify the request, signing, webhook, and scanned-PDF workflow against the live service. See the [go-live check](../development/docuseal_integration_guide.md#go-live-check).

## Audit & Event Tracking

- [ ] Move invoice generation and notification-failure audit writes in `Invoices::GenerationService` and `Invoices::Workflow` through `AuditEventService`, preserving their transaction and retry identities.
- [ ] Move `EmailDelivery::Outcome`, `Feedback`, and `LegacyMailJobs` audit writes through the canonical owner while preserving request-id deduplication and provider-event guards. Fix `LegacyMailJobs.remove!` deleting a queue job before its removal audit is durable; the queue and application stores require an explicit failure/retry contract.
- [ ] Event browsing: settle the query shape and the indexes it needs.
- [ ] Controller: `Admin::EventsController#index` (filters, pagination).
- [ ] CSV export: service + controller action, scoped to the filters.
- [ ] Rake: `audit:check` (missing creation events, orphaned events).
- [ ] Migration: add an index on `events.created_at`. The `(action, auditable_type, auditable_id)` and `(auditable_type, auditable_id)` indexes already exist.
- [ ] Apply `Applications::EventService` to guardian/dependent flows consistently.
- [ ] Tests: controller filters, CSV, rake task.

## Proofs, Statuses, Templates (Tech Debt)

- [ ] Pick where enums live, and whether complex metadata goes in JSON or a normalized schema.
- [ ] Module: centralize proof types in a shared module.
- [ ] Migration: add a JSON column for extended proof/status metadata (if chosen).
- [ ] Refactor: use the centralized enums and update references.
- [ ] Templates: standardize under `NotificationComposer` and remove one-offs.
- [ ] Tests: enum usage, JSON accessors (if applicable).

## Mobile Proofs Workflow

Uploads already check file type and size in the browser and show inline errors with a retry. What's left:

- [ ] Performance: measure upload timings and set target budgets.
- [ ] Reliability: Retry is manual today and only re-checks the scan. Spike automatic retry with backoff and resumable uploads for flaky mobile connections.
- [ ] Tests: upload error and retry paths at a mobile viewport.

## Optional / Larger Architectural Work

Consolidated `Proof` model
- [ ] Single table vs. polymorphic, the FK strategy, and a migration plan.
- [ ] Migration: create `proofs` + backfill rake task.
- [ ] Services: update `ProofAttachmentService`/`ProofReviewService` to use `Proof`.
- [ ] UI: read and write `Proof` records.
- [ ] Audit/events: include `proof_id` and `kind`.
- [ ] Tests: backfill correctness, services, UI reads.

## Why “MAT Vulcan”?

MAT stands for Maryland Accessible Telecommunications. Vulcan is the Roman god of the forge—a maker of equipment. Since MAT helps people get accessible telecommunications equipment, the name is a playful nod to that connection. A little mythology, a little wordplay; no relation to the Vulcans from Star Trek.

“Vulcan” is an internal nickname. Public-facing pages and messages use Maryland Accessible Telecommunications. Internal module, database, deployment, and synthetic-email identifiers retain their existing names; they are not display labels. The existing TOTP issuer also remains `MatVulcan`.

### Fax-provider replacement

Fax is off. The installed Twilio SDK has no fax API, so `FaxService` refuses to send. Choosing a replacement provider also settles whether we receive faxes. Before turning the transport back on, verify the provider and keep these in place: All/category enforcement, authorization of the original attempt, exact SID callback identity, idempotent fallback, and media ownership. Historical signed callbacks still work. Legacy and canceled attempts are never replayed automatically.
