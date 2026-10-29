# DocuSeal Integration

DocuSeal lets a medical provider sign an application's disability certification electronically.

The app sends the request, receives signing updates by webhook, and stores the returned PDF for staff review.

Signing and approval are independent: a provider can finish signing while the document is unreviewed, or while its download has failed.

## Two statuses

Both columns are on [`Application`](../../app/models/application.rb):

| Column | Question | Values |
| --- | --- | --- |
| `document_signing_status` | What happened in the signing flow? | `not_sent`, `sent`, `opened`, `signed`, `declined` |
| `disability_certification_status` | Where is the document in staff review? | `not_requested`, `requested`, `received`, `approved`, `rejected` |

Rejecting a certification does not unsign it: the signed file and its history stay available while staff request a correction.

## A request, end to end

The admin application page posts to `send_document_signing_request`. [`SubmissionService`](../../app/services/document_signing/submission_service.rb) requires a provider name, provider email, and an actor, and refuses a second request within 30 seconds of the last one. DocuSeal sends the provider's email itself, so the service checks the [All, Email and Certification controls](../infrastructure/email_system.md#delivery-controls) before calling DocuSeal; while email is off it makes no submission and changes no status, timestamp, or count, and the application page explains that nothing was sent, blank forms remain available, and outgoing letters follow their own controls. It asks DocuSeal to email the provider, stores the submission and submitter IDs, increments request counts, sets signing to `sent` and certification to `requested` with a status-history row and a `disability_certification_requested` audit event, and logs `document_signing_request_sent`. The request message uses the applicant's locale, with copy under `document_signing.disability_certification_request` in the [locale files](../../config/locales).

Signing updates arrive at `POST /webhooks/docuseal/disability_certification` ([controller](../../app/controllers/webhooks/docuseal_controller.rb)), matched to an application by submission ID and signing service. A completion downloads a private PDF snapshot and queues its antivirus scan. After a matching clean result, [`AcceptScannedDocument`](../../app/services/document_signing/accept_scanned_document.rb) rechecks the request and provider, then hands the file to [`DisabilityCertificationAttachmentService`](../../app/services/disability_certification_attachment_service.rb). Staff then approve or reject through the existing certification controls; [`DisabilityCertificationReviewer`](../../app/services/applications/disability_certification_reviewer.rb) handles rejection, issues a secure upload link for the correction, and asks [`MedicalProviderNotifier`](../../app/services/medical_provider_notifier.rb) to tell the provider.

| Event | Effect |
| --- | --- |
| `form.viewed` | Signing moves from `sent` to `opened`, audit event recorded. |
| `form.started` | Audit event recorded. |
| `form.completed` | PDF queued for scanning; signing becomes `signed` only after clean-file acceptance under the retention rules below. |
| `form.declined` | Unsigned requests move to `declined`, reason recorded in the audit event. |

Unknown event types and unmatched submission IDs change nothing, and the receiver still answers 200 — so a 200 from the webhook doesn't mean a document got attached.

### Which file wins

A certification can arrive through DocuSeal or a secure upload link. [`DisabilityCertificationAttachmentService.accept_submission`](../../app/services/disability_certification_attachment_service.rb) decides placement for both channels, so a correction and a late, obsolete completion are told apart the same way. Both require a clean antivirus result. The secure form resolves its staged upload through [`UploadedDocument`](../../app/services/uploaded_document.rb); DocuSeal downloads are bounded to the same 10 MB certification limit before staging:

| Current status | Submission | Result |
| --- | --- | --- |
| `not_requested` or `requested` | Any | Becomes the primary certification, status `received`. |
| `rejected` | Requested after the latest rejection | A correction: replaces the primary, status `received`. |
| `rejected` | Requested before the latest rejection | Kept in `additional_disability_certifications`, status unchanged. |
| `received` or `approved` | Any | Kept in `additional_disability_certifications`, status unchanged. |

The request time is the secure form's `sent_at`, or `document_signing_requested_at` for DocuSeal, which is written together with the submission ID the webhook must match. The rejection time is the latest rejected certification status change. A kept document is never discarded: its blob and the submission event record the reason, and the admin certification list shows it as a review note.

Completion callbacks must match the stored submission and submitter. Retries reuse the signing request's scan even when DocuSeal supplies a new download URL. Missing or invalid URLs, refused files and permanent download failures receive HTTP 200; temporary failures receive HTTP 503 so DocuSeal can retry. `document_signing_attachment_failed` records each failure reason once for that request.

PDF downloads require HTTPS and an exact host match: `docuseal.com`, `docuseal.eu`, or the host of the configured DocuSeal API URL. Other hosts, URL credentials, and redirects are refused before a document is staged. The cloud hosts match [DocuSeal's document links](https://www.docuseal.com/guides/download-signed-documents); a self-hosted instance uses the configured `base_url` host.

Pending, blocked, and failed scans do not mark signing complete or attach a document. The continuation ignores a superseded request and recognizes an already attached snapshot by blob ID. Its attachment, signing status, and completion audit commit together. Recovery allows at most three persisted acceptance attempts. A permanent failure, missing application or actor, or exhausted retry budget records a terminal failure and stops recovery for that scan. Send a new signing request after a terminal failure. See [attachment scanning](../security/attachment_scanning.md) for monitoring and recovery.

## Configuration

The [initializer](../../config/initializers/docuseal.rb) reads the `docuseal` credentials section; the webhook receiver reads the **top-level** `webhook_secret`:

```yaml
docuseal:
  api_key: YOUR_API_KEY
  # base_url: https://api.docuseal.com  # optional; only for a non-default DocuSeal instance
webhook_secret: whsec_YOUR_SIGNING_SECRET  # top level, copied from the DocuSeal console
```

`base_url` is optional and defaults to the value shown. Keep `webhook_secret` at the top level, never nested under `docuseal`: the receiver reads `credentials.webhook_secret` directly. A missing or blank secret rejects every request with HTTP 401; there is no fallback secret, and the stored value must match DocuSeal exactly.

For a DocuSeal EU account, use `base_url: https://api.docuseal.eu`.

### Webhook setup in the DocuSeal console

1. In the DocuSeal console (**Console → Webhooks → New Webhook**), register `https://<APPLICATION_HOST>/webhooks/docuseal/disability_certification` and select `form.viewed`, `form.started`, `form.completed`, and `form.declined`. The host is the deployed app's public `APPLICATION_HOST`, served over HTTPS. An unsigned `POST` to the URL should answer 401 (not 404) once the app is deployed there; that proves the route exists, not that signature verification will pass.
2. Copy the HMAC signing secret: with the webhook created, open **Security → HMAC** and reveal the masked `whsec_...` value. DocuSeal generates this value; you do not choose it. The adjacent **Secret** tab is a different feature, a static custom header pair, that this receiver does not use.
3. Store the value as the top-level `webhook_secret` with `EDITOR="vim" bin/rails credentials:edit`, commit the changed `config/credentials.yml.enc`, and deploy. If the webhook is deleted and recreated in the console, DocuSeal generates a new secret: recheck the **Security → HMAC** value after any webhook change and resync credentials when it changed, or callbacks are rejected again.

### Signature contract

[`Webhooks::DocusealController`](../../app/controllers/webhooks/docuseal_controller.rb) verifies `X-Docuseal-Signature: [timestamp].[signature]` using [DocuSeal's documented format](https://www.docuseal.com/resources/use-webhooks). The timestamp is Unix time in seconds; the signature is the hexadecimal HMAC-SHA256 of `[timestamp].[raw_body]`. Use the full `whsec_...` secret as the key, including its prefix, without decoding it. The raw body must be the exact request bytes, not parsed and re-serialized JSON.

The receiver compares signatures in constant time and rejects missing or malformed signatures, changed bodies, and timestamps more than five minutes before or after the server's current time with HTTP 401. Exactly five minutes is accepted, matching [DocuSeal's verifier](https://github.com/docusealco/docuseal/blob/master/lib/webhook_urls/signatures.rb). Keep the server clock accurate. The legacy body-only signature and `X-Webhook-Signature` header are not accepted for this endpoint.

Payload validation, event handling, and replay identity read only the signed request body. Query parameters cannot supply or override `event_type`, `data`, or the provider's event `timestamp`.

For `form.viewed`, `form.started`, and `form.declined`, the receiver requires the [documented event timestamp and submitter identity](https://www.docuseal.com/docs/api#form-webhook): top-level `timestamp`, `data.id` and `data.submission_id`. Retries of the same event write one audit event for the current signing request, even with a fresh signature or changed download URLs. Separate event timestamps preserve separate history. Missing or malformed identity receives HTTP 422; callbacks for a superseded request are acknowledged without changes. Delayed activity cannot move a signed or declined request back to opened, and a delayed decline cannot replace a signed result.

A valid signed callback can be delivered again within that window. Completion handling uses the stored signing request identity to avoid duplicate scans or attachments.

The outbound payload is built in `SubmissionService#create_submission!`, and the automated tests stub the provider API — a live account's template and submission setup, and its webhook authentication, need verifying against the real service. The payload does not yet pass a `template_id` to the create-submission API, so live submissions also need that payload change before they can succeed.

### Go-live check

1. Configure the credentials above, provision AttachmentScanner, and apply migrations in the target environment. Production requires `ATTACHMENT_SCANNER_URL` and `ATTACHMENT_SCANNER_API_TOKEN`. Run the Solid Queue worker and recurring recovery jobs described in [attachment scanning](../security/attachment_scanning.md). On Heroku, the release process migrates; inspect with `heroku run bin/rails db:migrate:status --app your-app-name`.
2. Register the webhook and its signing secret as described under [Webhook setup in the DocuSeal console](#webhook-setup-in-the-docuseal-console): URL `https://<APPLICATION_HOST>/webhooks/docuseal/disability_certification` for `form.viewed`, `form.started`, `form.completed`, and `form.declined`, with the console's `whsec_...` value stored as top-level credentials `webhook_secret`.
3. After supplying the signing template in the submission payload, send a request for a fresh, controlled application and provider address, complete signing, and confirm the snapshot stays unavailable while scanning. A clean result should attach the PDF, set signing to `signed`, and set certification status to `received` for this new application. Confirm a callback signed by DocuSeal passes authentication; an unsigned or stale callback should return HTTP 401.
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
| Attachment, review state, side effects | [`DisabilityCertificationAttachmentService`](../../app/services/disability_certification_attachment_service.rb) |
| Buttons, file display, signing badge | [certification section](../../app/views/admin/applications/_disability_certification_section.html.erb), [admin helper](../../app/helpers/admin/applications_helper.rb), [badge helper](../../app/helpers/application_helper.rb) |

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Cannot send | Missing provider name or email, API credentials, or the 30-second resend guard. |
| Webhook rejected | Missing or invalid signature, wrong secret, changed raw body, server clock outside the five-minute tolerance, or missing `event_type`/`data`. |
| Webhook accepted, nothing changed | Submission ID or `document_signing_service` mismatch — often an older request. |
| Provider finished, but no document appeared | Pending/blocked/failed scan, intake failure, stopped worker, or a superseded signing request. |
| Signed, but no new primary document | Additional certification retained because the primary was received, approved, or rejected after this signing request. |
| Correction needed after signing | Certification rejection plus the correction-upload flow; signing status records what already happened. |

```bash
bin/rails test test/services/document_signing/submission_service_test.rb test/controllers/webhooks/docuseal_controller_test.rb test/integration/document_signing_workflow_test.rb
```

The [webhook tests](../../test/controllers/webhooks/docuseal_controller_test.rb) are the fullest reference: signatures, event handling, file retention, repeat delivery, and attachment failures.
