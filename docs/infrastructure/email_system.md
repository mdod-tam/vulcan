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
| `bin/rails email_templates:audit` | Read-only comparison of expected seed and `MAILER_MAP` keys against the database; does not seed or update templates. |
| `bin/rails db:seed_policies` | Initializes the application's program policy defaults; see [baseline setup](setup_and_maintenance.md#baseline-seeds). |

The seeds are initialization tasks. Policy seeding updates differing values if rows already exist; template seeding replaces existing copy. Use the audit on its own to investigate template mismatches. It exits nonzero for missing or unexpected template keys. [Heroku setup](setup_and_maintenance.md#heroku-deployment-and-operations) includes the remote commands.

## Sending and printing

[`ApplicationMailer`](../../app/mailers/application_mailer.rb) provides shared rendering and delivery; workflow mailers choose recipients, variables, and whether postal preference applies.

Provider certification requests are queued by [`MedicalCertificationService`](../../app/services/applications/medical_certification_service.rb) as [`MedicalCertificationEmailJob`](../../app/jobs/medical_certification_email_job.rb), which sends via `MedicalProviderMailer` and records delivery errors on the notification when there is one ([job tests](../../test/jobs/medical_certification_email_job_test.rb)).

The job configures three total attempts, including the initial execution. Its `wait: :exponentially_longer` setting is unsupported by Rails 8.1, so an SMTP failure currently raises during retry scheduling instead of queuing the next attempt.

Letters are the same templates rendered to PDF: [`TextTemplateToPdfService`](../../app/services/letters/text_template_to_pdf_service.rb) produces a Prawn document attached to a `PrintQueueItem`, which staff print from `/admin/print_queue`. Template validation and locale fallback are shared with the email path.

Password-reset mail builds links from [`CanonicalPublicUrlOptions`](../../app/services/canonical_public_url_options.rb) rather than the request host. Those links are bearer credentials: they stay out of stored notification metadata, and delivery errors are sanitized. Registration confirmation is a plain message, not an email-verification flow.

## Collecting documents

Documents arrive through secure forms or staff upload. No live Action Mailbox implementation collects proofs or certifications in this checkout, and two leftover scripts imply otherwise: [`bin/test-inbound-email`](../../bin/test-inbound-email) calls the missing `MatVulcan::InboundEmailConfig`, and [`bin/test-inbound-emails`](../../bin/test-inbound-emails) targets a removed test file.

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

The webhook path is incomplete: it references `MedicalProviderEmail`, which has no model in this repository, and never updates `Notification` rows. Delivery and open tracking therefore exist for one notification type, not generally.

[`PostmarkDebugger`](../../config/initializers/postmark_debugger.rb) logs redacted payloads under `POSTMARK_DEBUG_PAYLOADS=true`, with bodies, contact values, URLs, and token fields removed — worth reaching for after the queued job, stream, template, and provider result have been ruled out.

## Delivery tracking

To refresh stored delivery status for medical-certification emails:

```bash
bin/rails notification_tracking:check_all
```

This queues `UpdateEmailStatusJob` for notifications with non-placeholder message IDs. A worker must process the jobs, which query Postmark and update notification records. Notifications without message IDs are skipped.

## Tests

[Renderer](../../test/services/email_templates/renderer_test.rb) · [locale](../../test/models/admin/email_templates_locale_test.rb) · [letter PDF](../../test/services/letters/text_template_to_pdf_service_test.rb) · [redaction](../../test/initializers/postmark_debugger_test.rb)

A change is covered when the resulting recipient, variables, letter routing, and failure handling are all asserted against the real template and locale. A queued job or a 200 from Postmark is not receipt.
