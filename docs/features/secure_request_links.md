# Secure request links

A secure request link lets someone complete one document task without a portal account. The link carries a random bearer token, and only its SHA-256 digest is stored.

| Link | Model | Recipient | Submission service |
| --- | --- | --- | --- |
| Proof resubmission | [`SecureRequestForm`](../../app/models/secure_request_form.rb) | Applicant or guardian | [`SubmitProofResubmission`](../../app/services/applications/submit_proof_resubmission.rb) |
| Provider information | `SecureRequestForm` | Applicant or guardian | [`SubmitProviderInfo`](../../app/services/applications/submit_provider_info.rb) |
| Certification upload | `SecureRequestForm` (`certification_upload` kind) | Certifying provider | [`SubmitCertificationUpload`](../../app/services/applications/submit_certification_upload.rb) |
| W9 upload | [`VendorSecureRequestForm`](../../app/models/vendor_secure_request_form.rb) | Vendor | [`SubmitW9Resubmission`](../../app/services/vendors/submit_w9_resubmission.rb) |

A certification link goes to the application's certifying provider, who is not a user. It has no user recipient and no delivery owner: the provider's email is in `recipient_email`, the name in `recipient_name`, and `recipient_role` is `provider`. Check constraints keep that true in both directions, and a unique index allows one active certification link per application, matching the issuer's replace-every-open-link rule. Certification pages resolve tokens through `SecureRequestForm.certification_upload`, so a proof or provider-information token never opens one, and the proof and provider-information pages refuse a certification token by kind. An application's `secure_request_forms` are the user-recipient links; its `certification_upload_forms` are the provider links.

Audit events and delivery tracking name a link with `secure_request_form_id` for every kind except W9, which uses `vendor_secure_request_form_id`.

## Timing

[`SecureFormPolicy`](../../app/services/secure_form_policy.rb) owns link timing and builds every public link URL.

| Policy key | Default | Effect |
| --- | --- | --- |
| `secure_form_link_expiration_hours` | 48 | How long a new link stays usable. The provider information email and the proof and provider information text messages state this value; proof, certification, and W9 emails do not. |
| `secure_form_resend_cooldown_hours` | 1 | How soon another link can be issued after the latest open one: per recipient for proof and provider information, per application for certification, and per vendor for W9. A submitted or revoked link starts no cooldown. |

`RecordSecureFormExpirationsJob` runs hourly in production ([schedule](../../config/recurring.yml)). It records one expiration event for each expired proof, certification, or W9 link that is still open, then sets `expiration_recorded_at` so later runs skip that form. Provider information links do not record an expiration event.

## Issuing a link

Issuance records the recipient and delivery details on the form row, and delivery sends to that recorded contact. A resend records the contact on file at that time, not the contact on the expired link, and revokes the open links it replaces.

Proof and provider-information commands use [`Applications::SecureRequestIssuance`](../../app/services/applications/secure_request_issuance.rb) for locked recipient resolution, replacement, and mandatory tracking. A failed tracking write rolls back the whole recipient batch, including replacement revocations. All four issuers replace links through [`SecureFormReplacement`](../../app/services/secure_form_replacement.rb). It applies the cooldown, revokes the open links as `replacement_request`, and creates the new link. [`SecureTokenizable`](../../app/models/concerns/secure_tokenizable.rb) creates tokens for all four link types and retries one digest collision inside a savepoint, and `SecureFormPolicy` computes the cooldown duration. The issuer owns the application or vendor lock, recipient rules, and which links count as open; every command checks only open links for its cooldown.

[`SecureRequestDeliveryPolicy`](../../app/services/applications/secure_request_delivery_policy.rb) shares transport and outcome handling. Transport failure revokes the failed link and allows other recipients to proceed. Failure to record a handoff after successful transport leaves the delivered link usable. The proof command attempts delivery after issuance; certification preparation still returns a URL to the separate provider-notice flow.

All four public resend endpoints use the `proof_submission` web rate limit. If both `proof_submission_rate_limit_web` and `proof_submission_rate_period` are missing, resends are blocked and a configuration warning is logged. A missing individual value uses the policy default. Throttled and configuration-blocked requests retain the same neutral public response and leave the expired link unchanged.

A link that carries a secure URL must actually be delivered. All four issuing services (proof, provider information, certification, W9) check the [email controls](../infrastructure/email_system.md#delivery-controls) before creating a link for an email recipient: if all email, the email's category, or its template is off, no link, token, revocation, or status change is created and the service reports the email as suppressed. If the email is stopped after the link was prepared, the service revokes the unsent link as `delivery_suppressed`, starts no resend cooldown, and a certification request moves back from requested when that request put it there. Missing or unreadable email settings are operational errors, not intentional suppression. An early configuration refusal creates no email request, while other letter or SMS recipients still proceed. A late configuration refusal uses the delivery-failure cleanup, as a transport error does: the unsent link is revoked without a resend cooldown. When a proof rejection cannot issue its link, `ProofDecisionFollowUp` records `proof_resubmission_request_failed`, and the application history shows the reason; a suppressed email is marked `delivery_suppressed` there. The rejection that archives the application issues no link, because the applicant is sent the archive notice instead; that is not a failed request.

Constituent links use the recipient's delivery locale for email, SMS, and pages. Provider certification emails and pages are English, because the applicant's locale says nothing about the provider's language. W9 links follow the vendor's locale.

### Certification request state and counts

[`DisabilityCertificationService`](../../app/services/applications/disability_certification_service.rb) records certification request state for both queued provider requests and secure upload preparation, through `Application#transition_disability_certification_status!`, which writes the status, history, and audit together. Each state write attaches the previous status, timestamp, and count to its tracking notification so a delivery refusal can restore that request without replacing newer state.

`disability_certification_request_count` counts the ordinary provider requests queued by `DisabilityCertificationService` (including resends) and the separate DocuSeal signing requests. It is recorded at issuance, before confirmed delivery; an intentional or configuration refusal restores the unchanged queued request's previous count. Transport failures retain the request for failure tracking. Issuing or resending a secure upload link leaves this count unchanged, including when the secure issuer delivers the link directly. Rejection review also prepares a link for a separate provider notifier. Preparation changes `not_requested` to `requested` once; later links retain certification status, timestamp, and count, including `rejected`.

## Submitting

Each public controller shares one flow from [`SecureRequestFormController`](../../app/controllers/secure_request_form_controller.rb):

- A link that is missing, of the wrong kind, revoked, or already submitted shows that state. A submitted link shows as submitted even when it was also revoked.
- A submit on a link that can no longer be used redirects with 303 to the link's page, which shows the current state. Turbo ignores a 200 response to a form submission, so a rendered page would leave the user on a form that did nothing.
- An expired link redirects to the resend page. A resend request always redirects to the same neutral page, so the response does not show whether a link exists.
- Validation errors render with 422. Other failures show a translated message; diagnostics identify the error class and form rather than logging private exception text.

Submission services share [`SecureFormSubmission`](../../app/services/concerns/secure_form_submission.rb). The upload control first stages a private file for [antivirus scanning](../security/attachment_scanning.md), owned by that exact secure form. Scanning does not consume or extend the link. After clearance, final submission sends the signed file reference, and [`UploadedDocument`](../../app/services/uploaded_document.rb) checks ownership, purpose, content, and clearance inside the submission transaction. A raw file or another form's reference is refused. Limits come from [`ProofUploadFormats`](../../app/models/proof_upload_formats.rb): proofs up to 5 MB, certifications up to 10 MB, W9 files under 10 MB, and at least 1 KB on each secure form. [`ProofAttachmentValidator`](../../app/services/proof_attachment_validator.rb) identifies type from bytes and checks PDF active content. A refused file rolls the transaction back, so the request stays unused, and the form re-renders with 422 and the translated reason from `documents.refused`. If the link expires or is revoked while scanning, the file cannot be accepted through it; the uploader needs a new link.

Proof, provider-information, and certification submissions lock the application before the form, in the same order as issuance, and recheck the link under those locks:

- **Proof:** the proof must still be requestable (`ProofManageable#proof_requestable_via_secure_form?`), which is rejected, or never uploaded and not reviewed. A proof approved or replaced by another path refuses the upload and records `proof_secure_submission_refused`. So does an archived application, which `ProofReview` also refuses to review.
- **Provider information:** an active request accepts valid provider details. When they replace a value already on file, the change event is marked for staff review.
- **Certification:** an archived application refuses the upload and records `cert_secure_submission_refused`; the link stays unused. Otherwise `DisabilityCertificationAttachmentService.accept_submission` places the document; see [which file wins](../development/docuseal_integration_guide.md#which-file-wins). Certification status never refuses an upload: a late or obsolete one is kept aside. `Application#certification_requestable_via_secure_form?` is the rule, shared with issuance, the admin send button, and the scan step, as `proof_requestable_via_secure_form?` is for proofs.
- **W9:** submission locks the vendor before the nested form lock, checks form ownership, and rechecks the vendor's requestability and the link's active state. Replay or a newly ineligible vendor leaves the form unconsumed and writes no W9.

## Revoking

`revoke!` locks the form. It does nothing, and records no event, when the form is already submitted or revoked, so a revocation cannot overwrite a submission that finished first. Admin revoke actions report that case as not active.

An active provider information link stays visible, and can be revoked, after other staff work completes the provider information.

## Checking a change

The [public form matrix](../../test/controllers/secure_public_form_matrix_test.rb) checks show, update, and resend responses for its listed link states across all four form families. [Delivery contract tests](../../test/services/applications/secure_link_delivery_contract_test.rb) use real mailers for recipients and disabled templates. The [terminal state system test](../../test/system/secure_form_terminal_state_test.rb) submits revoked and already submitted links through Turbo.
