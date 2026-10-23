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

The admin application page posts to `send_document_signing_request`. [`SubmissionService`](../../app/services/document_signing/submission_service.rb) requires a provider name, provider email, and an actor, and refuses a second request within 30 seconds of the last one. DocuSeal sends the provider's email itself, so the service checks the [All, Email and Certification controls](../infrastructure/email_system.md#delivery-controls) before calling DocuSeal; while email is off it makes no submission and changes no status, timestamp, or count, and the application page explains that nothing was sent, blank forms remain available, and outgoing letters follow their own controls. It asks DocuSeal to email the provider, stores the submission and submitter IDs, increments request counts, sets signing to `sent` and certification to `requested`, and logs `document_signing_request_sent`. The request message uses the applicant's locale, with copy under `document_signing.medical_certification_request` in the [locale files](../../config/locales).

Signing updates arrive at `POST /webhooks/docuseal/medical_certification` ([controller](../../app/controllers/webhooks/docuseal_controller.rb)), matched to an application by submission ID and signing service. A completion downloads a private PDF snapshot and queues its antivirus scan. After a matching clean result, [`AcceptScannedDocument`](../../app/services/document_signing/accept_scanned_document.rb) rechecks the request and provider, then hands the file to [`MedicalCertificationAttachmentService`](../../app/services/medical_certification_attachment_service.rb). Staff then approve or reject through the existing certification controls; [`MedicalCertificationReviewer`](../../app/services/applications/medical_certification_reviewer.rb) handles rejection, issues a secure upload link for the correction, and asks [`MedicalProviderNotifier`](../../app/services/medical_provider_notifier.rb) to tell the provider.

| Event | Effect |
| --- | --- |
| `form.viewed` | Signing set to `opened`, audit event recorded. |
| `form.started` | Audit event recorded. |
| `form.completed` | PDF queued for scanning; signing becomes `signed` only after clean-file acceptance under the retention rules below. |
| `form.declined` | Signing set to `declined`, reason recorded in the audit event. |

Unknown event types and unmatched submission IDs change nothing, and the receiver still answers 200 — so a successful webhook response is not evidence that a document was attached.

### Which file wins

A certification can arrive through DocuSeal or a secure upload link. [`MedicalCertificationAttachmentService.accept_submission`](../../app/services/medical_certification_attachment_service.rb) decides placement for both channels, so a correction and a late, obsolete completion are told apart the same way. Both require a clean antivirus result. The secure form resolves its staged upload through [`UploadedDocument`](../../app/services/uploaded_document.rb); DocuSeal downloads are bounded to the same 10 MB certification limit before staging:

| Current status | Submission | Result |
| --- | --- | --- |
| `not_requested` or `requested` | Any | Becomes the primary certification, status `received`. |
| `rejected` | Requested after the latest rejection | A correction: replaces the primary, status `received`. |
| `rejected` | Requested before the latest rejection | Kept in `additional_medical_certifications`, status unchanged. |
| `received` or `approved` | Any | Kept in `additional_medical_certifications`, status unchanged. |

The request time is the secure form's `sent_at`, or `document_signing_requested_at` for DocuSeal, which is written together with the submission ID the webhook must match. The rejection time is the latest rejected certification status change. A kept document is never discarded: its blob and the submission event record the reason, and the admin certification list shows it as a review note.

A missing URL, failed download, or failed intake returns HTTP 503 so DocuSeal can retry; `document_signing_attachment_failed` records the failure. Pending, blocked, and failed scans do not mark signing complete or attach a document. The continuation ignores a superseded request and recognizes an already attached snapshot by blob ID. Its attachment, signing status, and completion audit commit together. Recovery retries an unfinished clean continuation safely. See [attachment scanning](../security/attachment_scanning.md) for monitoring and terminal-failure recovery.

## Configuration

The [initializer](../../config/initializers/docuseal.rb) reads the `docuseal` credentials section; the webhook receiver reads the **top-level** `webhook_secret`:

```yaml
docuseal:
  api_key: YOUR_API_KEY
  # base_url: https://api.docuseal.com  # optional; only for a non-default DocuSeal instance
webhook_secret: whsec_YOUR_SIGNING_SECRET  # top level, copied from the DocuSeal console
```

`base_url` is optional and defaults to the value shown. Keep `webhook_secret` at the top level, never nested under `docuseal`: the receiver reads `credentials.webhook_secret` directly. A missing or blank secret rejects every request with HTTP 401; there is no fallback secret, and the stored value must match DocuSeal exactly.

### Webhook setup in the DocuSeal console

1. In the DocuSeal console (**Console → Webhooks → New Webhook**), register `https://<APPLICATION_HOST>/webhooks/docuseal/medical_certification` and select `form.viewed`, `form.started`, `form.completed`, and `form.declined`. The host is the deployed app's public `APPLICATION_HOST`, served over HTTPS. An unsigned `POST` to the URL should answer 401 (not 404) once the app is deployed there; that proves the route exists, not that signature verification will pass.
2. Copy the HMAC signing secret: with the webhook created, open **Security → HMAC** and reveal the masked `whsec_...` value. DocuSeal generates this value; you do not choose it. The adjacent **Secret** tab is a different feature, a static custom header pair, that this receiver does not use.
3. Store the value as the top-level `webhook_secret` with `EDITOR="vim" bin/rails credentials:edit`, commit the changed `config/credentials.yml.enc`, and deploy. If the webhook is deleted and recreated in the console, DocuSeal generates a new secret: recheck the **Security → HMAC** value after any webhook change and resync credentials when it changed, or callbacks are rejected again.

### Signature contract and current gap

DocuSeal (2.5.3 and later) signs each webhook as `X-Docuseal-Signature: [timestamp].[signature]`, where `signature` is the SHA-256 HMAC of `[timestamp].[raw_body]` computed with the `whsec_...` secret, and timestamps older than five minutes are stale. The current receiver instead compares a SHA-256 HMAC of the raw request body alone, in either `X-Webhook-Signature` or `X-DocuSeal-Signature`, with an optional `sha256=` prefix; [`Webhooks::BaseController`](../../app/controllers/webhooks/base_controller.rb) owns the shared calculation. These formats do not match: until the receiver verifies DocuSeal's timestamp format, correctly signed callbacks are still rejected with HTTP 401 and webhook-driven processing cannot go live. Receiver support for the DocuSeal format is planned work.

The outbound payload is built in `SubmissionService#create_submission!`, and the automated tests stub the provider API — a live account's template and submission setup, and its webhook authentication, need verifying against the real service. The payload does not yet pass a `template_id` to the create-submission API, so live submissions also need that payload change before they can succeed.

### Go-live check

1. Configure the credentials above, provision AttachmentScanner, and apply migrations in the target environment. Production requires `ATTACHMENT_SCANNER_URL` and `ATTACHMENT_SCANNER_API_TOKEN`. Run the Solid Queue worker and recurring recovery jobs described in [attachment scanning](../security/attachment_scanning.md). On Heroku, the release process migrates; inspect with `heroku run bin/rails db:migrate:status --app your-app-name`.
2. Register the webhook and its signing secret as described under [Webhook setup in the DocuSeal console](#webhook-setup-in-the-docuseal-console): URL `https://<APPLICATION_HOST>/webhooks/docuseal/medical_certification` for `form.viewed`, `form.started`, `form.completed`, and `form.declined`, with the console's `whsec_...` value stored as top-level credentials `webhook_secret`.
3. Send a request for a fresh, controlled application and provider address, complete signing, and confirm the snapshot stays unavailable while scanning. A clean result should attach the PDF, set signing to `signed`, and set certification status to `received` for this new application. This step requires the receiver's signature-format fix; until it ships, DocuSeal's correctly signed callbacks are still rejected with HTTP 401.
4. Review that PDF through the normal admin certification controls. If it remains unavailable, inspect the scan status, `document_signing_attachment_failed`, and worker logs before retrying.

## Changing the public host

Moving the app to a different public host — for example from a `*.herokuapp.com` domain to a program domain — touches this integration alongside the host-wide settings:

1. Update `APPLICATION_HOST` on the deployed app. It feeds the webhook URL registered in the console, the post-signing `completed_redirect_url` that `SubmissionService` builds, generated email links, and the WebAuthn allowed origin.
2. Re-register the DocuSeal webhook for the new host, then recheck its **Security → HMAC** value: if DocuSeal shows a new `whsec_...` secret, copy it into credentials `webhook_secret` and deploy, or callbacks are rejected.
3. Keep the old webhook registered until traffic has fully moved, then remove it so stale events stop.

A host change also affects settings outside this integration: existing security keys can require reenrollment ([settings that must match](../infrastructure/backup_and_recovery.md#must-settings-match-the-original-instance)).

## Where changes go

| Concern | File |
| --- | --- |
| Request payload, message, request tracking | [`DocumentSigning::SubmissionService`](../../app/services/document_signing/submission_service.rb) |
| Incoming events and signed PDF handling | [`Webhooks::DocusealController`](../../app/controllers/webhooks/docuseal_controller.rb) |
| Clean-file continuation | [`DocumentSigning::AcceptScannedDocument`](../../app/services/document_signing/accept_scanned_document.rb) |
| Attachment, review state, side effects | [`MedicalCertificationAttachmentService`](../../app/services/medical_certification_attachment_service.rb) |
| Buttons, file display, signing badge | [certification section](../../app/views/admin/applications/_medical_certification_section.html.erb), [admin helper](../../app/helpers/admin/applications_helper.rb), [badge helper](../../app/helpers/application_helper.rb) |

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Cannot send | Missing provider name or email, API credentials, or the 30-second resend guard. |
| Webhook rejected | Signature header, secret, exact raw body, missing `event_type`/`data`, or the signature-format gap above. |
| Webhook accepted, nothing changed | Submission ID or `document_signing_service` mismatch — often an older request. |
| Provider finished, but no document appeared | Pending/blocked/failed scan, intake failure, stopped worker, or a superseded signing request. |
| Signed, but no new primary document | Additional certification retained because the primary was received, approved, or rejected after this signing request. |
| Correction needed after signing | Certification rejection plus the correction-upload flow; signing status records what already happened. |

```bash
bin/rails test test/services/document_signing/submission_service_test.rb test/controllers/webhooks/docuseal_controller_test.rb test/integration/document_signing_workflow_test.rb
```

The [webhook tests](../../test/controllers/webhooks/docuseal_controller_test.rb) are the fullest reference: signatures, event handling, file retention, repeat delivery, and attachment failures.
