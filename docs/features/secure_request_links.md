# Secure request links

A secure request link lets someone complete one document task without a portal account. The link carries a random bearer token, and only its SHA-256 digest is stored.

| Link | Model | Recipient | Submission service |
| --- | --- | --- | --- |
| Proof resubmission | [`SecureRequestForm`](../../app/models/secure_request_form.rb) | Applicant or guardian | [`SubmitProofResubmission`](../../app/services/applications/submit_proof_resubmission.rb) |
| Provider information | `SecureRequestForm` | Applicant or guardian | [`SubmitProviderInfo`](../../app/services/applications/submit_provider_info.rb) |
| Certification upload | [`MedicalProviderSecureRequestForm`](../../app/models/medical_provider_secure_request_form.rb) | Certifying provider | [`SubmitCertificationUpload`](../../app/services/applications/submit_certification_upload.rb) |
| W9 upload | [`VendorSecureRequestForm`](../../app/models/vendor_secure_request_form.rb) | Vendor | [`SubmitW9Resubmission`](../../app/services/vendors/submit_w9_resubmission.rb) |

## Timing

[`SecureFormPolicy`](../../app/services/secure_form_policy.rb) owns link timing and builds every public link URL.

| Policy key | Default | Effect |
| --- | --- | --- |
| `secure_form_link_expiration_hours` | 48 | How long a new link stays usable. The provider information email and the proof and provider information text messages state this value; proof, certification, and W9 emails do not. |
| `secure_form_resend_cooldown_hours` | 1 | How soon another link can be issued: per recipient for proof and provider information, per application for certification, and per vendor for W9. |

`RecordSecureFormExpirationsJob` runs hourly in production ([schedule](../../config/recurring.yml)). It records one expiration event for each expired proof, certification, or W9 link that is still open, then sets `expiration_recorded_at` so later runs skip that form. Provider information links do not record an expiration event.

## Issuing a link

Issuance records the recipient and delivery details on the form row, and delivery sends to that recorded contact. A resend records the contact on file at that time, not the contact on the expired link, and revokes the open links it replaces.

A link that carries a secure URL must actually be delivered. All four issuing services (proof, provider information, certification, W9) check the [email controls](../infrastructure/email_system.md#delivery-controls) before creating a link for an email recipient: if all email, the email's category, or its template is off, no link, token, revocation, or status change is created and the service reports the email as suppressed. If the email is stopped after the link was prepared, the service revokes the unsent link as `delivery_suppressed`, starts no resend cooldown, and a certification request moves back from requested when that request put it there. Missing or unreadable email settings are operational errors, not intentional suppression. An early configuration refusal creates no email request, while other letter or SMS recipients still proceed. A late configuration refusal uses the delivery-failure cleanup, as a transport error does: the unsent link is revoked without a resend cooldown. When a proof rejection cannot issue its link, `ProofReview` records `proof_resubmission_request_failed`, and the application history shows the reason; a suppressed email is marked `delivery_suppressed` there.

Constituent links use the recipient's delivery locale for email, SMS, and pages. Provider certification emails and pages are English, because the applicant's locale says nothing about the provider's language. W9 links follow the vendor's locale.

### Certification request state and counts

[`MedicalCertificationService`](../../app/services/applications/medical_certification_service.rb) records certification request state, status history, and audit for both queued provider requests and secure upload preparation. Each state write attaches the previous status, timestamp, and count to its tracking notification so a delivery refusal can restore that request without replacing newer state.

`medical_certification_request_count` counts the ordinary provider requests queued by `MedicalCertificationService` (including resends) and the separate DocuSeal signing requests. It is recorded at issuance, before confirmed delivery; an intentional or configuration refusal restores the unchanged queued request's previous count. Transport failures retain the request for failure tracking. Issuing or resending a secure upload link leaves this count unchanged, including when the secure issuer delivers the link directly. Rejection review also prepares a link for a separate provider notifier. Preparation changes `not_requested` to `requested` once; later links retain certification status, timestamp, and count, including `rejected`.

## Submitting

Each public controller shares one flow from [`SecureRequestFormController`](../../app/controllers/secure_request_form_controller.rb):

- A link that is missing, of the wrong kind, revoked, or already submitted shows that state. A submitted link shows as submitted even when it was also revoked.
- A submit on a link that can no longer be used redirects with 303 to the link's page, which shows the current state. Turbo ignores a 200 response to a form submission, so a rendered page would leave the user on a form that did nothing.
- An expired link redirects to the resend page. A resend request always redirects to the same neutral page, so the response does not show whether a link exists.
- Validation errors render with 422. Other failures show a translated message only, and the raw error goes to the log.

Submission services share [`SecureFormSubmission`](../../app/services/concerns/secure_form_submission.rb). Proof, certification, and W9 uploads resolve the file through [`UploadedDocument`](../../app/services/uploaded_document.rb) inside the submission transaction, accepting only an uploaded file, never a signed blob ID. Limits come from [`ProofUploadFormats`](../../app/models/proof_upload_formats.rb): proofs up to 5 MB, certifications up to 10 MB, W9 files under 10 MB, and at least 1 KB on every secure form. [`ProofAttachmentValidator`](../../app/services/proof_attachment_validator.rb) then checks the real type and PDF active content. A refused file rolls the transaction back, so the request stays active, and the form re-renders with 422 and the translated reason from `documents.refused`. Type detection can still fall back to the file extension, so a file named `.pdf` is not proven to be a PDF.

Submission locks the application before the form, in the same order as issuance, and rechecks the link under that lock:

- **Proof:** the proof must still be requestable (`ProofManageable#proof_requestable_via_secure_form?`), which is rejected, or never uploaded and not reviewed. A proof approved or replaced by another path refuses the upload and records `proof_secure_submission_refused`.
- **Provider information:** a submission is always accepted. When it replaces a value already on file, the change event is marked for staff review.
- **Certification:** `MedicalCertificationAttachmentService.accept_submission` places the document; see [which file wins](../development/docuseal_integration_guide.md#which-file-wins).

## Revoking

`revoke!` locks the form. It does nothing, and records no event, when the form is already submitted or revoked, so a revocation cannot overwrite a submission that finished first. Admin revoke actions report that case as not active.

An active provider information link stays visible, and can be revoked, after other staff work completes the provider information.

## Checking a change

The [public form matrix](../../test/controllers/secure_public_form_matrix_test.rb) checks every link state for every form and resend endpoint. [Delivery contract tests](../../test/services/applications/secure_link_delivery_contract_test.rb) use real mailers for recipients and disabled templates. The [terminal state system test](../../test/system/secure_form_terminal_state_test.rb) submits revoked and already submitted links through Turbo.
