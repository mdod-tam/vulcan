# Outgoing communications: email, letters and SMS

Message templates live in the database, not in `app/views`.

Mailers fill them with workflow data and either send through Postmark or render a PDF for staff to print.

Which workflow owns a given communication is decided in [notifications](../features/notifications.md).

## Templates

Staff edit, preview, and test-send at `/admin/email_templates`. An [`EmailTemplate`](../../app/models/email_template.rb) is identified by name, format, and locale; [`EmailTemplates::Renderer`](../../app/services/email_templates/renderer.rb) renders subject and body in one of two syntaxes:

| Syntax | What authors get |
| --- | --- |
| `legacy_percent` | Declared required and optional placeholders — `%{first_name}`, `%<first_name>s`. |
| `liquid` | Exact required-variable paths such as `{{ application.id }}`. No optional variables, filters, or control tags. |

A variable has to be both declared and supplied by the sending workflow: editing template text never adds data the mailer does not pass. Subject, body, and syntax edits bump the version; subject and body edits keep the prior content for the Previous Version panel. These content changes flag counterpart locales for review, except when updating an already out-of-sync translation. Description-only edits do not flag other locales.

### Seed and audit tasks

| Command | Effect |
| --- | --- |
| `bin/rails db:seed_manual_email_templates` | Initializes templates from the [checked-in files](../../lib/tasks/seed_manual_email_templates.rake); deletes existing templates first, including staff edits. |
| `bin/rails email_templates:audit` | Read-only comparison of expected seed and catalog template keys against the database; does not seed or update templates. |
| `bin/rails db:seed_policies` | Initializes the application's program policy defaults; see [baseline setup](setup_and_maintenance.md#baseline-seeds). |

The seeds are initialization tasks. Policy seeding updates differing values if rows already exist; template seeding replaces existing copy. Use the audit on its own to investigate template mismatches. It exits nonzero for missing or unexpected template keys. [Heroku setup](setup_and_maintenance.md#heroku-deployment-and-operations) includes the remote commands.

## Sending and printing

[`ApplicationMailer`](../../app/mailers/application_mailer.rb) provides shared rendering and delivery; workflow mailers choose recipients, variables, and whether postal preference applies.

Provider certification requests are queued by [`MedicalCertificationService`](../../app/services/applications/medical_certification_service.rb) as [`MedicalCertificationEmailJob`](../../app/jobs/medical_certification_email_job.rb), which sends via `MedicalProviderMailer` and records delivery errors on the notification when there is one ([job tests](../../test/jobs/medical_certification_email_job_test.rb)).

The job configures three total attempts with Rails polynomial backoff. It defers enqueue until commit and binds the exact notification. Early policy refusal creates no delivery-owned request state; late refusal or enqueue failure restores only that attempt’s unchanged state. A newer request, including a DocuSeal request in the same second, takes precedence.

Letters are the same templates rendered to PDF: [`TextTemplateToPdfService`](../../app/services/letters/text_template_to_pdf_service.rb) produces a Prawn document attached to a `PrintQueueItem`, which staff print from `/admin/print_queue`. Mailers pass their resolved message locale into PDF rendering so the template, shared fragments and PDF labels agree even when a guardian owns the postal address. Secure requests use their recorded delivery owner's locale. Both rendering paths validate templates and fall back to the default-locale template when the requested translation is missing.

Mailer error audits store the action, template and sanitized diagnostics, without template variables. Proof and provider-info requests share delivery execution and failure cleanup; their issuing services retain recipient, token and cooldown rules. Configuration refusals remain distinct from transport errors and intentional suppression in service results and revocation audits. Password recovery records the same distinction internally while keeping its public response uniform.

Password-reset mail builds links from [`CanonicalPublicUrlOptions`](../../app/services/canonical_public_url_options.rb) rather than the request host. Those links are bearer credentials: they stay out of stored notification metadata, and delivery errors are sanitized. Registration confirmation is a plain message, not an email-verification flow.

## Delivery controls

Delivery requires **All → channel → category → applicable template → original authorization**. Staff manage these on `/admin/email_templates`:

1. `communications.global`: **All outgoing communications**. Off blocks new email, SMS, authentication/setup texts, letter admission and PDF release. It dominates a channel saved as On.
2. Independent channels: `email.global` (**Email**, preserving the existing key), `communications.letters` (**Printed letters**), and `communications.sms` (**SMS**).
3. Existing `email.category.*` controls apply across channels: proof, registration, voucher, vendor, certification, training, evaluation, account security, application. Password recovery remains separate from registration.
4. A template switch controls EN/ES together for email and letters that render it. Template-less SMS/provider actions use catalog categories without a fictitious template.

Each change preserves settings underneath it. The page shows saved and effective state; a missing control is a configuration error, never a normal Off setting or a reason to send. Turning Email off leaves eligible letters/SMS working; turning All off stops all three. Sample previews, public blank DCF forms and ordinary record/invoice PDFs remain available. No refusal silently reroutes a letter to email.

Bulk template enable/disable applies the existing template pairs in one transaction, including their cancellation generations, individual audit events and one summary. A failed pair or audit leaves the entire batch unchanged and displays an error. Retrying the same operation does not reverse a later change. A successful bulk disable schedules one letter-reconciliation job after commit; release checks remain authoritative while it waits. The bulk buttons change templates only; use All to stop template-less provider and SMS actions too.

Committed changes to a recipient's captured identity fields, or an application's applicant/guardian ownership, schedule scoped reconciliation of unreleased letters. The worker rechecks eligibility under locks and preserves valid replacement letters and released history. Pending letters that are no longer eligible display as blocked awaiting cancellation; cancellation is shown only after it is persisted. Rollbacks and unrelated edits do not schedule reconciliation. Failed scheduling is reported through `letter_reconciliation_enqueue_failed` when the system audit actor is available; the release gate still refuses stale letters.

Fax sending is explicitly unavailable: the installed Twilio SDK (7.10.4) has no fax resource. Provider replacement is a separate follow-up, not part of this control rollout. Signed callbacks still record matching historical fax outcomes. Legacy callbacks without captured authorization cannot create email fallback; captured attempts cannot regain authorization after an off/on interval. Fallback outcomes are separate from fax history. A claimed-but-unfinished fallback requires staff investigation and deliberate reissue, never automatic replay.

Shared headers and footers (`email_header_text`, `email_footer_text`) are fragments rendered inside other templates. They are never sent on their own, have no on/off setting, cannot be test-sent, and are skipped by the bulk buttons; their stored `enabled` value is ignored. Browser previews always work; a test send follows All, Email, the category of the template being tested, and that template's setting, and the page says whether it was queued or why it was not sent.

The test-email page sanitizes HTML-format preview snippets, preserving safe formatting while removing scripts and event handlers. Voucher dates and generated message fragments use the recipient locale in both email and printed-letter rendering.

Deduplication lookups for email request ids and control operation ids use `Event.with_metadata`, backed by the existing JSONB GIN index.

Only [`EmailDelivery::ControlWriter`](../../app/services/email_delivery/control_writer.rb) changes a control or a template pair. Turning one off bumps its generation in the same transaction and records `email_control_changed` or `email_template_pair_toggled` with the operation id; a retried operation id is applied once, and a form submitted against a setting someone else has since changed is refused. The generic feature-flag screen, `features:enable`/`features:disable`, and direct model updates cannot change a communication control or a template's `enabled` value.

| Task | Use |
| --- | --- |
| `bin/rails email_delivery:controls` | Show All, channel and category controls and their generations. |
| `bin/rails 'email_delivery:set_global[off]'` / `[on]` | Change only the Email channel. Use `set_all` to stop every channel. |
| `bin/rails 'email_delivery:set_all[off]'` / `[on]` | Stop or permit new requests across all channels, preserving saved channel settings. |
| `bin/rails email_delivery:legacy_letter_report` | Inventory unreleased letters lacking version-2 authorization. |
| `bin/rails email_delivery:reconcile_letters` | Cancel ineligible unreleased letters; revoke only their unreleased secure requests. Never reauthorize an old PDF. |
| `bin/rails email_delivery:template_pair_report` | Read-only list of template pairs whose English and Spanish settings disagree, and which locale would stop sending. |
| `bin/rails email_delivery:reconcile_template_pairs` | Turn those pairs off (the approved conservative policy). Each change is audited and cancels that pair's pending email; a rerun changes nothing. |

Until a mismatched pair is reconciled, the policy already treats it as off, because every locale row of the pair must be on.

Queued mail runs through [`EmailDelivery::MailDeliveryJob`](../../app/jobs/email_delivery/mail_delivery_job.rb), which captures context before Rails defers enqueue callbacks until commit. The capture includes the originating notification id and the row id and generation of All, each supported channel, the category, and every locale row of its template when the message is requested. `ApplicationMailer`'s `before_deliver` check verifies that capture right before handoff; immediate deliveries capture and verify at that moment. Mail captured before the control was turned off stays canceled after it is turned back on, a channel denied when requested stays denied (an independently eligible letter route may still run), and a recreated control row does not authorize it.

The policy decision retains both its outcome and its reason through issuance, enqueue, and delivery. Intentional refusal records `email_delivery_suppressed`; missing or unreadable configuration records `email_delivery_configuration_error`. Both prevent transmission. When there is a tracking notification, the locked outcome writer sets channel `none` and either `suppressed` or `error`, with a readable reason. Routing and error-handler updates cannot overwrite a worker's refusal with stale metadata. Suppression is visible even without a provider message id; configuration failure is not described as an administrator turning email off.

Email outcome events, invoice job events, and voucher job events use the configured system audit account without creating or promoting one. The voucher status callback uses the current actor when present and otherwise the same lookup-only system attribution. If that account is absent, invoices and expirations still run but unattributable events are skipped and logged. Voucher expiry warnings are skipped because their audit event is what limits each voucher to one warning. New warnings record `expiration_warning_requested` with the enqueue outcome and request ID, not a claim of delivery. Intentional suppression consumes that warning; immediate configuration or queue errors leave it eligible for a later run. Existing `expiration_warning_sent` history still prevents duplicates. `PublicAuditActor` emits `system_audit_actor_missing`; the email outcome recorder emits `email_delivery_audit_actor_missing.email_delivery`. Provision the system administrator explicitly before rollout; normal business operations must never repair its identity or privileges.

### Catalog

[`EmailDelivery::Catalog`](../../app/services/email_delivery/catalog.rb) lists every mailer action with its category, routing (`email_only`, `preference`, or `email`), template, and owning service, and every notification action with the argument adapter `NotificationService` uses. `NotificationService`'s action lists and the template audit's aliases are derived from it. An action missing from the catalog is blocked at delivery as an `unclassified_action` configuration error. [The catalog test](../../test/services/email_delivery/catalog_test.rb) fails CI when a mailer action is unclassified, a catalog entry no longer exists, or an adapter's arguments do not fit its mailer; add the catalog entry in the same change as a new mailer action.

An `email_only` action that is denied is never queued. A `preference` action may queue when at least one of its channels is eligible. The mailer resolves the recipient’s preference and checks that channel; an eligible sibling channel does not authorize the selected one or silently change the preference.

### Secure-link requests

The four secure-link owners (`Vendors::RequestW9Resubmission`, `Applications::RequestCertificationUpload`, `Applications::RequestProofResubmission`, `Applications::RequestProviderInfo`) check the selected channel before creating its request. An intentional denial creates no request, token, revocation, or status change, and returns a `delivery_suppressed` result; independently eligible recipients in the same batch proceed, and prepare-only calls are unaffected. When an email is stopped after its request was prepared — a disabled template or a control changed at the last moment — the owner revokes the unsent link with reason `delivery_suppressed` instead of reporting a delivery failure. A revoked request starts no resend cooldown. The owners keep the context they checked and pass it to `EmailDelivery.deliver_now!`, so the final check verifies the authorization the link was prepared under; a control turned off and on in between still cancels it. A message stopped there becomes `ApplicationMailer::DeliverySkipped` for the owner. When a proof rejection's upload request is suppressed, the rejection still stands, its `proof_resubmission_request_failed` event carries `delivery_suppressed`, and the admin sees that the email was turned off rather than that delivery failed.

Configuration refusal is separate from intentional suppression. An early refusal creates no request for the affected channel and reports a settings error; independently eligible recipients in a batch still proceed. At synchronous handoff, it raises `EmailDelivery::ConfigurationError`, and the request owner uses its delivery-failure cleanup to revoke the unsent link without starting a cooldown. It does not become `DeliverySkipped`. Admin test sends and DocuSeal report the settings error without claiming a switch is off. Prepare-only behavior and public account-recovery responses stay unchanged.

`MedicalCertificationEmailJob` sends its email inside its own job, so it captures the controls when it is queued ([`EmailDeliveryContextJob`](../../app/jobs/concerns/email_delivery_context_job.rb)); a suppressed send is recorded on its notification and is not retried.

Rails reports `successfully_enqueued?` optimistically inside an open transaction. The shared job's `around_enqueue` callback observes the actual write after commit: it records both Rails' stored `ActiveJob::EnqueueError` and Solid Queue's raised `SolidQueue::Job::EnqueueError` as `email_delivery_enqueue_failed`. It also marks the originating notification `error`, with channel `none` and a readable queue-failure message. Adapter exception messages are not stored because they can contain serialized arguments. Other exceptions propagate normally.

`EmailDelivery.deliver_later` distinguishes `queued`, `deferred`, `suppressed`, `configuration_error`, and `enqueue_failed`. `deferred` is an intent inside an open transaction; the post-commit callback records a later refusal or queue failure on the notification. Outside a transaction, `queued` means accepted by the queue, not delivered. Invoice, evaluation, and training business changes remain committed when their email cannot be queued. Preference-routed messages can still be refused by the worker after it resolves the channel. Production's Solid Queue tables live in the application database but use their own connection, so the queue write is never part of the application transaction; [the queue boundary test](../../test/integration/mail_queue_boundary_test.rb) runs against that arrangement, including real database insert failures.

The check applies at handoff, so it cannot recall a message a provider already accepted. Mail jobs queued by a release before this job class existed bypass the capture and must be cleared during rollout.

### Releasing the delivery controls

This is a coordinated cutover. Old workers do not understand All/Letters/SMS or context version 2. Do not mix old and new send-capable processes, and do not treat maintenance mode alone as stopping workers or one-off jobs.

1. Inventory the deployed version, **every** FeatureFlag row and default-true caller, EN/ES pair mismatches, pending jobs in `ActionMailer::MailDeliveryJob`, `EmailDelivery::MailDeliveryJob`, and `MedicalCertificationEmailJob`, and all pending/printed print items. Confirm mismatched pairs and the channels that will stop. The new All row inherits the old Email setting; if Email was Off, letters and SMS will also be blocked at cutover. Existing channel/category settings are preserved.
2. Confirm a real administrator can sign in with TOTP/passkey or another existing non-SMS method before disabling communications. All Off blocks new password-recovery and verification messages, but does not block verification of an already-issued code. Do not create/promote an audit actor or bypass MFA as a recovery strategy. Provision `system@mdmat.org` through the established administrator process if missing; rollout tasks refuse to invent it.
3. Stop web, workers, recurring schedulers and one-off senders; inventory processes and wait for in-flight handoffs. Messages accepted by providers, downloaded PDFs and previously issued service URLs cannot be recalled.
4. Deploy and migrate with senders stopped. The migration is additive and rerunnable: it preserves existing settings/generations and adds nullable letter authorization/history fields plus the unique request-key index. Do not stamp current authorization onto legacy jobs or PDFs.
5. Run `email_delivery:set_all[off]`, `legacy_mail_job_report` then `remove_legacy_mail_jobs`, `legacy_letter_report` then `reconcile_letters`, and the template-pair report/reconciliation tasks. Version-1 and context-less mail/wrapper jobs are canceled. Legacy unreleased letters are canceled and deliberately reissued if still required; historical printed items remain history. Physically released pre-upgrade items cannot be inferred from `pending`: reconcile that inventory with staff before cutover. Do not mark them freshly authorized automatically.
6. Verify the saved settings with `email_delivery:controls`, then restart current-version workers and web. Exercise All Off through email, SMS/MFA and print release; no provider call or PDF release is allowed. Confirm existing TOTP/passkey access and blank/reference downloads. Then enable All and the intended individual channels. Use controlled recipients to verify email streams, SMS and letter release/print confirmation.
7. Monitor policy configuration errors, unknown classifications, enqueue failures, missing audit actors and pending letter-reconciliation jobs. Existing `email_delivery_*` audit/instrumentation names are retained for shared policy refusals. A reconciliation failure cannot authorize export: original generations are always checked at release. `reconcile_letters` is the idempotent recovery operation. Watch claimed fax fallbacks; investigate ambiguous handoffs before any deliberate new request.

To roll back, stop every sender first. Keep the additive schema and cancellation history; reverting to old code reopens bypasses even when All is Off. Reconcile jobs and physical artifacts before restoring traffic. Do not run the destructive down migration or restore/reset control IDs while pending requests exist. App/queue transactions and provider handoffs are not atomic; `released_at` records authorized release, not proof that a browser received or printed bytes.

### Printed-letter lifecycle

Both template letters and manual DCF requests use `Letters::Delivery`. Renderers retain their layouts. A database-unique logical request key replaces process-local deduplication; retries keep the same key and canceled work never resurrects. Manual DCF forms include an operation ID; a deliberate new form submission creates a new request. Evaluator confirmations use the evaluation/submission identity.

Admission captures controls and a digest of recipient/address/locale and owner identity. Release rechecks that identity, the original controls, attachment identity and active secure request. Address changes and duplicate merges cancel unreleased work; released/printed history is not reassigned. Secure-request cancellation revokes only the exact unreleased form and removes its active cooldown claim. `sent_at` remains the issuance timestamp, not physical delivery evidence.

`/admin/print_queue` separates awaiting release, released awaiting print confirmation, printed and canceled items. GET displays metadata only. Authenticated, CSRF-protected POST prepares the entire PDF/ZIP before atomically authorizing release; failed or partially ineligible batches release nothing. Every ZIP entry includes its item ID. Staff mark printed only after physical printing. Re-downloads obey current and original authorization without erasing prior release history. Print attachments cannot bypass release through public Active Storage blob/proxy/disk routes; ordinary uploads and historical fax media retain their contracts. Previously downloaded bytes or external signed URLs cannot be revoked by this switch.

### Historical imports

No importer exists in this repository (checked at the start of this work), so these controls govern the application's own sending paths and do not by themselves prove anything about an import. An importer added later must mark the records it creates as imported, suppress any email, request, or workflow step triggered only because a record was imported, keep that suppression when email is turned back on and when the import or a job is retried, and still let the person's later, unrelated email (a password reset, a new application) follow the normal controls. It must not use `Current.paper_context`, disabled callbacks, or raw status writes to do so.

## Collecting documents

Documents arrive through secure forms or staff upload. No Action Mailbox implementation collects proofs or certifications.

A disabled template pair skips its email and records `email_delivery_suppressed`. For the secure-link emails the issuing service creates no link in the first place, or revokes one prepared just before the template was turned off; see [secure request links](../features/secure_request_links.md). Provider certification emails use the default locale.

| Request | Issuing / submitting |
| --- | --- |
| Missing or rejected income, residency, ID proof | [`RequestProofResubmission`](../../app/services/applications/request_proof_resubmission.rb) / [`SubmitProofResubmission`](../../app/services/applications/submit_proof_resubmission.rb) |
| Provider certification upload | [`RequestCertificationUpload`](../../app/services/applications/request_certification_upload.rb) / [`SubmitCertificationUpload`](../../app/services/applications/submit_certification_upload.rb) |

These own the form and token lifecycle, delivery result, attachment validation, and history — an ordinary mailer call produces a message without any of it.

Recipient and channel for constituent-facing requests come from [`SecureRequestRecipientResolver`](../../app/services/applications/secure_request_recipient_resolver.rb); provider certification requests address the recorded provider contact instead. The routing rules behind it:

- An explicit channel choice must have usable contact details and an eligible recipient and owner. An invalid choice fails rather than quietly falling back to another channel.
- SMS is only ever an explicit selection with a real text-capable phone. Automatic proof-rejection delivery never picks it.
- Letters can serve address-only recipients. Guardian and dependent contact ownership is field-by-field ([guardian relationships](../development/guardian_relationship_system.md)).
- Every new form stores its delivery owner and source. Email and phone snapshots describe the destination as issued; letter rows have no address snapshot. The stored owner controls message language.
- A resend revalidates the original channel against current eligible contact and creates a replacement form. It neither rewrites the old form's history nor redirects a merged recipient to the survivor.

[Merge checks](../../app/services/users/duplicate_merge_service.rb) read that ownership history, and active forms missing owner or source data currently block merges globally. Ownership cannot be inferred backwards from present-day contact data, so legacy links have to expire or be revoked:

1. `SecureRequestForm.active.with_incomplete_delivery_provenance.count` inventories them; the [scope](../../app/models/secure_request_form.rb) catches rows missing either field.
2. Let them expire, or revoke them through the request workflow.
3. Recheck, and issue fresh requests to current eligible recipients where the documents are still needed.

Two resolver reasons explain most delivery refusals: `invalid_channel_override` (the selected channel has no usable contact — SMS also needs a text-capable number) and `recipient_no_longer_eligible` (actor, recipient, delivery owner, or required relationship failed the locked eligibility check).

## Postmark

| Concern | Where |
| --- | --- |
| Adapter and credential | [Application config](../../config/application.rb), `credentials.postmark_api_token` |
| Message stream | `ApplicationMailer` defaults to `notifications`; [`UserMailer`](../../app/mailers/user_mailer.rb) uses `outbound` for password resets |
| Tracking | [postmark_format.rb](../../config/initializers/postmark_format.rb) — open tracking on, link tracking off |
| Stored facts | [`EmailDeliveryAttempt`](../../app/models/email_delivery_attempt.rb) stores acceptance and independent recipient feedback |
| Delivery/bounce/complaint/open webhook | [`EmailEventsController`](../../app/controllers/webhooks/email_events_controller.rb) → [`EmailDelivery::Feedback`](../../app/services/email_delivery/feedback.rb) |

For a new Postmark server:

1. Configure its server API token in Rails credentials and authorize the configured sender, `no_reply@mdmat.org`, through a verified domain or confirmed sender signature. See [Postmark's sender setup](https://postmarkapp.com/support/article/adding-sender-signatures).
2. Ensure the server has the `notifications` and `outbound` message streams used by the mailers.
3. Run `bin/rails email_templates:audit`, then test both streams with controlled records and recipient addresses: a proof-resubmission request sent by email exercises `notifications`; a password reset exercises `outbound` and the generated public-host link. `/admin/email_templates` also supports queued test sends, but those use Postmark's default stream and do not verify the workflow's stream selection.
4. Confirm the password-reset job runs and both messages arrive; proof-resubmission requests send synchronously. On Heroku, inspect `heroku ps --app your-app-name` and `heroku logs --tail --dyno worker --app your-app-name`; the [worker setup](setup_and_maintenance.md#heroku-deployment-and-operations) is separate from the token and template setup.

The email-specific endpoint uses required HTTP Basic credentials and a matching Postmark server ID. Other webhook controllers keep their existing authentication. Enable feedback only after following the [deployment and rollback runbook](postmark_delivery_visibility.md). This code change does not configure production webhooks or send test messages.

[`PostmarkDebugger`](../../config/initializers/postmark_debugger.rb) logs redacted payloads under `POSTMARK_DEBUG_PAYLOADS=true`, with bodies, contact values, URLs, and token fields removed — worth reaching for after the queued job, stream, template, and provider result have been ruled out.

## Delivery tracking

[`ApplicationMailer`](../../app/mailers/application_mailer.rb) records a durable attempt before the common synchronous/queued transport boundary. Provider acceptance uses `X-PM-Message-Id`; the RFC `Message-ID` is stored separately. A notification can link several attempts, and mail without a notification still has transport history. The [runbook](postmark_delivery_visibility.md) explains correlation, retries, destination ownership, privacy and rollout.

Authenticated webhooks are the primary feedback path. To queue a bounded fallback check:

```bash
bin/rails notification_tracking:check_all
```

The hourly job handles at most 100 eligible attempts per run. Each unconfirmed attempt gets at most eight checks, at least an hour apart, within seven days. Confirmed delivery, bounce, complaint or definite transport failure ends routine polling. Opens never keep polling alive. A failed check preserves last-known facts and records tracking unavailability separately.

Shared EN/ES delivery badges and keyboard-accessible details appear in notification and request histories and the relevant authorized detail screens. Request lifecycle, provider delivery, print handling and DocuSeal remain separate facts. Application/contact attention only includes actionable requests; a bounce at an old address does not label a replacement address bad. Delivered means receiving-server acceptance; an open signal is not proof of human reading.

Historical notifications without an attempt show **Delivery unknown**, even if an old notification contains a placeholder or RFC message ID. `notification_tracking:backfill` and `:analyze` report these records without changing them; `:fix_duplicates` is retired without deleting history. The notification's existing enum remains the owner of local queue, suppression and configuration outcomes. Provider facts never overwrite it.

## Tests

[Renderer](../../test/services/email_templates/renderer_test.rb) · [locale](../../test/models/admin/email_templates_locale_test.rb) · [letter PDF](../../test/services/letters/text_template_to_pdf_service_test.rb) · [redaction](../../test/initializers/postmark_debugger_test.rb)

A change is covered when the resulting recipient, variables, letter routing, and failure handling are all asserted against the real template and locale. A queued job or a 200 from Postmark is not receipt.
