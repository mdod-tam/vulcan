# Email and Letters

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

The job configures three total attempts, including the initial execution. Its `wait: :exponentially_longer` setting is unsupported by Rails 8.1, so an SMTP failure currently raises during retry scheduling instead of queuing the next attempt.

Letters are the same templates rendered to PDF: [`TextTemplateToPdfService`](../../app/services/letters/text_template_to_pdf_service.rb) produces a Prawn document attached to a `PrintQueueItem`, which staff print from `/admin/print_queue`. Template validation and locale fallback are shared with the email path.

Password-reset mail builds links from [`CanonicalPublicUrlOptions`](../../app/services/canonical_public_url_options.rb) rather than the request host. Those links are bearer credentials: they stay out of stored notification metadata, and delivery errors are sanitized. Registration confirmation is a plain message, not an email-verification flow.

## Delivery controls

Three levels decide whether an email goes out, all managed on `/admin/email_templates`:

1. `email.global`, the master control. It stops every email, including password recovery, DocuSeal requests, and admin test sends.
2. One control per category (`email.category.proof`, `registration`, `voucher`, `vendor`, `certification`, `training`, `evaluation`, `account_security`, `application`). The [catalog](#catalog) assigns each email to one. Password recovery is `account_security`, so turning registration off leaves it running.
3. Each template pair: one on/off setting covers the English and Spanish rows of a template name and format.

Controls are `feature_flags` rows and template rows each carry a `delivery_generation`. Turning the master control off keeps category and template settings as they were, and turning a category off keeps its templates' settings; the page shows both the saved setting and whether email actually goes out ("On · Email suppressed: all email is turned off"). None of this stops printed letters or SMS: a letter-preference route never calls `mail`, so it prints as before.

Shared headers and footers (`email_header_text`, `email_footer_text`) are fragments rendered inside other templates. They are never sent on their own, have no on/off setting, cannot be test-sent, and are skipped by the bulk buttons; their stored `enabled` value is ignored. Browser previews always work; a test send follows the master control, the category of the template being tested, and that template's setting, and the page says whether it was queued or why it was not sent.

Only [`EmailDelivery::ControlWriter`](../../app/services/email_delivery/control_writer.rb) changes a control or a template pair. Turning one off bumps its generation in the same transaction and records `email_control_changed` or `email_template_pair_toggled` with the operation id; a retried operation id is applied once, and a form submitted against a setting someone else has since changed is refused. The generic feature-flag screen, `features:enable`/`features:disable`, and direct model updates cannot change an email control or a template's `enabled` value.

| Task | Use |
| --- | --- |
| `bin/rails email_delivery:controls` | Show the master and category controls and their generations. |
| `bin/rails 'email_delivery:set_global[off]'` / `[on]` | Turn all email off or on, for example around a release. |
| `bin/rails email_delivery:template_pair_report` | Read-only list of template pairs whose English and Spanish settings disagree, and which locale would stop sending. |
| `bin/rails email_delivery:reconcile_template_pairs` | Turn those pairs off (the approved conservative policy). Each change is audited and cancels that pair's pending email; a rerun changes nothing. |

Until a mismatched pair is reconciled, the policy already treats it as off, because every locale row of the pair must be on.

Queued mail runs through [`EmailDelivery::MailDeliveryJob`](../../app/jobs/email_delivery/mail_delivery_job.rb), which is queued after the caller's transaction commits and captures the row id and generation of the master control, the email's category control, and every locale row of its template when the email is requested. `ApplicationMailer`'s `before_deliver` check verifies that capture right before handoff; immediate deliveries capture and verify at that moment. Mail captured before the control was turned off stays canceled after it is turned back on, mail requested while a control was off stays denied (only its letter route, if any, still runs), and a recreated control row does not authorize it.

The policy decision retains both its outcome and its reason through issuance, enqueue, and delivery. Intentional refusal records `email_delivery_suppressed`; missing or unreadable configuration records `email_delivery_configuration_error`. Both prevent transmission. When there is a tracking notification, the locked outcome writer sets channel `none` and either `suppressed` or `error`, with a readable reason. Routing and error-handler updates cannot overwrite a worker's refusal with stale metadata. Suppression is visible even without a provider message id; configuration failure is not described as an administrator turning email off.

Email outcome events, invoice job events, and voucher job events use the configured system audit account without creating or promoting one. The voucher status callback uses the current actor when present and otherwise the same lookup-only system attribution. If that account is absent, invoices and expirations still run but unattributable events are skipped and logged. Voucher expiry warnings are skipped because their audit event is what limits each voucher to one warning. `PublicAuditActor` emits `system_audit_actor_missing`; the email outcome recorder emits `email_delivery_audit_actor_missing.email_delivery`. Provision the system administrator explicitly before rollout; normal business operations must never repair its identity or privileges.

### Catalog

[`EmailDelivery::Catalog`](../../app/services/email_delivery/catalog.rb) lists every mailer action with its category, routing (`email_only`, `preference`, or `email`), template, and owning service, and every notification action with the argument adapter `NotificationService` uses. `NotificationService`'s action lists and the template audit's aliases are derived from it. An action missing from the catalog is blocked at delivery as an `unclassified_action` configuration error. [The catalog test](../../test/services/email_delivery/catalog_test.rb) fails CI when a mailer action is unclassified, a catalog entry no longer exists, or an adapter's arguments do not fit its mailer; add the catalog entry in the same change as a new mailer action.

An `email_only` action that is denied is never queued. A `preference` action still runs so a letter-preference recipient gets a letter; only its email is stopped at the final check.

### Secure-link requests

The four secure-link owners (`Vendors::RequestW9Resubmission`, `Applications::RequestCertificationUpload`, `Applications::RequestProofResubmission`, `Applications::RequestProviderInfo`) check the controls before creating a request for an email recipient. An intentionally disabled email creates no request, token, revocation, or status change, and returns a `delivery_suppressed` result; letter and SMS recipients in the same batch proceed, and prepare-only calls are unaffected. When an email is stopped after its request was prepared — a disabled template or a control changed at the last moment — the owner revokes the unsent link with reason `delivery_suppressed` instead of reporting a delivery failure. A revoked request starts no resend cooldown. The owners keep the context they checked and pass it to `EmailDelivery.deliver_now!`, so the final check verifies the authorization the link was prepared under; a control turned off and on in between still cancels it. A message stopped there becomes `ApplicationMailer::DeliverySkipped` for the owner. When a proof rejection's upload request is suppressed, the rejection still stands, its `proof_resubmission_request_failed` event carries `delivery_suppressed`, and the admin sees that the email was turned off rather than that delivery failed.

Configuration refusal is separate from intentional suppression. An early refusal creates no email request and reports a settings error; other letter or SMS recipients in a batch still proceed. At synchronous handoff, it raises `EmailDelivery::ConfigurationError`, and the request owner uses its delivery-failure cleanup to revoke the unsent link without starting a cooldown. It does not become `DeliverySkipped`. Admin test sends and DocuSeal report the settings error without claiming a switch is off. Prepare-only behavior and public account-recovery responses stay unchanged.

`MedicalCertificationEmailJob` sends its email inside its own job, so it captures the controls when it is queued ([`EmailDeliveryContextJob`](../../app/jobs/concerns/email_delivery_context_job.rb)); a suppressed send is recorded on its notification and is not retried.

A queue write that fails after the caller's transaction commits raises nothing: the job object reports `successfully_enqueued?` as true inside the transaction and false afterwards. The mail job records these as `email_delivery_enqueue_failed` events; `EmailDelivery.deliver_later` distinguishes `queued`, `suppressed`, `configuration_error`, and `enqueue_failed`. Invoice and evaluation business changes remain committed when their email is refused. `queued` means accepted by the queue, not delivered; preference-routed messages can still be refused by the worker after it resolves the channel. Production's Solid Queue tables live in the application database but use their own connection, so the queue write is never part of the application transaction; [the queue boundary test](../../test/integration/mail_queue_boundary_test.rb) runs against that arrangement.

The check applies at handoff, so it cannot recall a message a provider already accepted. Mail jobs queued by a release before this job class existed bypass the capture and must be cleared during rollout.

### Releasing the delivery controls

Workers from a release without the controls ignore them, and mail they queued carries no captured settings. Release with sending stopped. The `email_delivery:*` tasks exist only in the new release, so the inventory before the deploy uses `bin/rails runner` against the running one (set `MAT_APP` as in [Heroku operations](setup_and_maintenance.md#heroku-deployment-and-operations)).

1. **Inventory the running release.** Record the deployed version, then run read-only queries with `heroku run --app "$MAT_APP" -- bin/rails runner '<script>'`:
   - Feature flags: `pp FeatureFlag.order(:name).pluck(:name, :enabled)`. A stored false now reads as false even where the code defaults to true; in this codebase that is `docusign_enabled`, which hides the DocuSeal button when false.
   - English/Spanish mismatches: `pp EmailTemplate.where.not(name: %w[email_header_text email_footer_text]).group(:name, :format).having("COUNT(DISTINCT enabled) > 1").pluck(:name, :format)`, then `pp EmailTemplate.where(name: <names>).pluck(:name, :format, :locale, :enabled)` for the listed names. Each pair will be turned off; have the product owner confirm the locales that stop sending.
   - Waiting mail jobs: `pp SolidQueue::Job.where(finished_at: nil, class_name: %w[ActionMailer::MailDeliveryJob MedicalCertificationEmailJob]).group(:class_name).count`.
2. **Stop everything that can send.** Freeze deploys and manual `heroku run` jobs, turn on maintenance mode, then scale `web` and `worker` to zero and confirm `heroku ps` lists no dynos. Maintenance mode alone leaves the worker and one-off dynos running. Account recovery email is unavailable until step 6.
3. **Deploy.** The release phase runs the migrations, which add the generation columns and the master and category controls, all on; existing template settings, ids, and content are unchanged.
4. **Before anything can send**, with `web` and `worker` still at zero, run one-off commands in this order. The tasks attribute their changes to the system administrator (`system@mdmat.org`) and stop if it is not configured; they never create it.
   1. `bin/rails 'email_delivery:set_global[off]'`, so nothing sends while you verify.
   2. `bin/rails email_delivery:remove_legacy_mail_jobs` removes the jobs counted in step 1 (one audit event each, without recipient data).
   3. `bin/rails email_delivery:template_pair_report`, compare it with the confirmed list, then `bin/rails email_delivery:reconcile_template_pairs`.
   4. `bin/rails email_delivery:controls` shows all email off and every category on.
5. **Verify with all email off.** Scale `worker` up, then `web`, and turn maintenance off. Sign in as an administrator and check the controls panel on `/admin/email_templates`: all email off, categories and templates as expected, reconciled pairs off. Email requested now is recorded as suppressed and will not send later; letters still print.
6. **Turn email on** from the panel or with `bin/rails 'email_delivery:set_global[on]'`. Send one controlled test email per stream (see the Postmark steps below), then watch for `email_delivery_suppressed`, `email_delivery_configuration_error`, `email_delivery_enqueue_failed`, `email_delivery_audit_actor_missing`, and `system_audit_actor_missing` events and logs, and for the invoice and voucher jobs.

To stop all email later without a deploy, use the panel or `bin/rails 'email_delivery:set_global[off]'`. Rolling back to a release without the controls brings back workers that ignore them: keep sending stopped, and do not delete suppression records or replay canceled email. Before restoring a database or resetting an id sequence, stop sending and reconcile pending jobs first, because canceled mail is identified by row id and generation.

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
| Stored status | [`UpdateEmailStatusJob`](../../app/jobs/update_email_status_job.rb) polls only `medical_certification_requested` notifications that have a message ID |
| Bounce/complaint webhook | [`EmailEventsController`](../../app/controllers/webhooks/email_events_controller.rb) → [`EmailEventHandler`](../../app/services/email_event_handler.rb) |

For a new Postmark server:

1. Configure its server API token in Rails credentials and authorize the configured sender, `no_reply@mdmat.org`, through a verified domain or confirmed sender signature. See [Postmark's sender setup](https://postmarkapp.com/support/article/adding-sender-signatures).
2. Ensure the server has the `notifications` and `outbound` message streams used by the mailers.
3. Run `bin/rails email_templates:audit`, then test both streams with controlled records and recipient addresses: a proof-resubmission request sent by email exercises `notifications`; a password reset exercises `outbound` and the generated public-host link. `/admin/email_templates` also supports queued test sends, but those use Postmark's default stream and do not verify the workflow's stream selection.
4. Confirm the password-reset job runs and both messages arrive; proof-resubmission requests send synchronously. On Heroku, inspect `heroku ps --app your-app-name` and `heroku logs --tail --dyno worker --app your-app-name`; the [worker setup](setup_and_maintenance.md#heroku-deployment-and-operations) is separate from the token and template setup.

The bounce/complaint webhook does not work. An authenticated event that reaches `EmailEventHandler` looks up `MedicalProviderEmail`, which has no model in this repository; the handler rescues the error and returns false, and the controller answers 422. The controller's check that skips processing when the model is missing only helps the test suite, and the webhook tests are skipped, so nothing covers this path. It never updates `Notification` rows. As of September 28, 2026, production Postmark sends to no outbound webhook (all four message streams have empty webhook lists and the legacy outbound webhook URLs are empty), so the broken route receives nothing; the separate inbound-email hook is configured and stays. Removing or rebuilding the route is a follow-up, not part of the delivery controls. Delivery and open tracking therefore exist for one notification type, not generally.

[`PostmarkDebugger`](../../config/initializers/postmark_debugger.rb) logs redacted payloads under `POSTMARK_DEBUG_PAYLOADS=true`, with bodies, contact values, URLs, and token fields removed — worth reaching for after the queued job, stream, template, and provider result have been ruled out.

## Delivery tracking

To refresh stored delivery status for medical-certification emails:

```bash
bin/rails notification_tracking:check_all
```

This queues `UpdateEmailStatusJob` for notifications with non-placeholder message IDs. A worker must process the jobs, which query Postmark and update notification records. Notifications without message IDs are skipped.

[`EmailDelivery::ProviderStatus`](../../app/services/email_delivery/provider_status.rb) maps Postmark's message status: `Queued` becomes `queued`, and `Sent` or `Processed` become `submitted` — the provider has the message, which is not the same as the recipient receiving it. Only a delivery or open timestamp sets `delivered` or `opened`. An unrecognized value is stored as `provider_status` with `provider_status_unrecognized` and leaves the status unchanged, and a poll never moves a status backward. A notification that is `suppressed` or `error` is not polled again. When Postmark cannot be reached the job records `status_check_failed_at` and checks again later instead of marking the email failed. Errors are stored under `delivery_error.message`, which `Notification#email_error_message` reads.

`delivery_status` values: `queued`, `submitted`, `delivered`, `opened`, `error`, and `suppressed` (intentionally not sent; the reason is under `delivery_suppressed`).

## Tests

[Renderer](../../test/services/email_templates/renderer_test.rb) · [locale](../../test/models/admin/email_templates_locale_test.rb) · [letter PDF](../../test/services/letters/text_template_to_pdf_service_test.rb) · [redaction](../../test/initializers/postmark_debugger_test.rb)

A change is covered when the resulting recipient, variables, letter routing, and failure handling are all asserted against the real template and locale. A queued job or a 200 from Postmark is not receipt.
