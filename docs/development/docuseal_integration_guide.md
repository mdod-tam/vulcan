# DocuSeal Integration

DocuSeal lets a medical provider sign an application's disability certification electronically.

The app sends the request, receives signing updates by webhook, and stores the returned PDF for staff review.

In code the document is still a `medical_certification`.

Signing and approval are independent: a provider can finish signing while the document is unreviewed, or while its download has failed.

## Two statuses

Both columns are on [`Application`](../../app/models/application.rb):

| Column | Question | Values |
| --- | --- | --- |
| `document_signing_status` | What happened in the signing flow? | `not_sent`, `sent`, `opened`, `signed`, `declined` |
| `medical_certification_status` | Where is the document in staff review? | `not_requested`, `requested`, `received`, `approved`, `rejected` |

Rejecting a certification does not unsign it: the signed file and its history stay available while staff request a correction.

## A request, end to end

The admin application page posts to `send_document_signing_request`. [`SubmissionService`](../../app/services/document_signing/submission_service.rb) requires a provider name, provider email, and an actor, and refuses a second request within 30 seconds of the last one. It asks DocuSeal to email the provider, stores the submission and submitter IDs, increments request counts, sets signing to `sent` and certification to `requested`, and logs `document_signing_request_sent`. The request message uses the applicant's locale, with copy under `document_signing.medical_certification_request` in the [locale files](../../config/locales).

Signing updates arrive at `POST /webhooks/docuseal/medical_certification` ([controller](../../app/controllers/webhooks/docuseal_controller.rb)), matched to an application by submission ID and signing service. A completion normally downloads the PDF and hands it to [`MedicalCertificationAttachmentService`](../../app/services/medical_certification_attachment_service.rb), which records it as received. Staff then approve or reject through the existing certification controls; [`MedicalCertificationReviewer`](../../app/services/applications/medical_certification_reviewer.rb) handles rejection, issues a secure upload link for the correction, and asks [`MedicalProviderNotifier`](../../app/services/medical_provider_notifier.rb) to tell the provider.

| Event | Effect |
| --- | --- |
| `form.viewed` | Signing set to `opened`, audit event recorded. |
| `form.started` | Audit event recorded. |
| `form.completed` | Signing marked complete; the PDF is processed by the retention rules below. |
| `form.declined` | Signing set to `declined`, reason recorded in the audit event. |

Unknown event types and unmatched submission IDs change nothing, and the receiver still answers 200 — so a successful webhook response is not evidence that a document was attached.

### Which file wins

A certification can arrive through several channels, and a late DocuSeal completion must not overwrite work already done elsewhere:

- **Normal completion** attaches the signed PDF as the primary certification and marks it `received`.
- **A secure upload already received, and certification is `received`, `approved`, or `rejected`** — that file and status stay, and the DocuSeal PDF is kept in `additional_medical_certifications` for comparison. The distinction comes from the `cert_submitted_via_secure_form` audit event.
- **Already approved without that secure-upload history** — the approved file and status are preserved, and the signing URLs are recorded without attaching the incoming PDF.

A failed download or attachment can leave signing at `signed` while certification never becomes `received`; the reason is in `document_signing_attachment_failed`. Completion processing also skips an application already marked signed with a stored document URL, and checks additional files by URL to avoid duplicate attachments.

## Configuration

The [initializer](../../config/initializers/docuseal.rb) reads the `docuseal` credentials section; the webhook receiver reads the **top-level** `webhook_secret`:

```yaml
docuseal:
  api_key: YOUR_API_KEY
  base_url: https://api.docuseal.com
webhook_secret: YOUR_WEBHOOK_SECRET
```

`base_url` is optional and defaults to the value shown.

The receiver expects a SHA-256 HMAC of the raw request body, in either `X-Webhook-Signature` or `X-DocuSeal-Signature`, with an optional `sha256=` prefix; [`Webhooks::BaseController`](../../app/controllers/webhooks/base_controller.rb) owns the shared calculation. With no secret configured the shared code falls back to a test value, which is worth knowing before assuming signature verification is active.

The outbound payload is built in `SubmissionService#create_submission!`, and the automated tests stub the provider API — a live account's template and submission setup, and its webhook authentication, need verifying against the real service.

### Go-live check

1. Configure the credentials above and apply migrations in the target environment. On Heroku, the release process migrates; inspect with `heroku run bin/rails db:migrate:status --app your-app-name`.
2. Register `https://your-public-host/webhooks/docuseal/medical_certification` in DocuSeal for `form.viewed`, `form.started`, `form.completed`, and `form.declined`. Verify that delivery satisfies this application's signature contract; registering the URL alone does not establish compatibility.
3. Send a request for a fresh, controlled application and provider address, complete signing, and confirm the callback attaches the PDF with certification status `received`.
4. Review that PDF through the normal admin certification controls. If signing is complete but the attachment is missing, inspect `document_signing_attachment_failed` and the target environment's logs before retrying.

## Where changes go

| Concern | File |
| --- | --- |
| Request payload, message, request tracking | [`DocumentSigning::SubmissionService`](../../app/services/document_signing/submission_service.rb) |
| Incoming events and signed PDF handling | [`Webhooks::DocusealController`](../../app/controllers/webhooks/docuseal_controller.rb) |
| Attachment, review state, side effects | [`MedicalCertificationAttachmentService`](../../app/services/medical_certification_attachment_service.rb) |
| Buttons, file display, signing badge | [certification section](../../app/views/admin/applications/_medical_certification_section.html.erb), [admin helper](../../app/helpers/admin/applications_helper.rb), [badge helper](../../app/helpers/application_helper.rb) |

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Cannot send | Missing provider name or email, API credentials, or the 30-second resend guard. |
| Webhook rejected | Signature header, secret, exact raw body, or missing `event_type`/`data`. |
| Webhook accepted, nothing changed | Submission ID or `document_signing_service` mismatch — often an older request. |
| Signed, but no new primary document | Attachment-failure events, additional certifications, or an existing approved file that was preserved. |
| Correction needed after signing | Certification rejection plus the correction-upload flow; signing status records what already happened. |

```bash
bin/rails test test/services/document_signing/submission_service_test.rb test/controllers/webhooks/docuseal_controller_test.rb test/integration/document_signing_workflow_test.rb
```

The [webhook tests](../../test/controllers/webhooks/docuseal_controller_test.rb) are the fullest reference: signatures, event handling, file retention, repeat delivery, and attachment failures.
