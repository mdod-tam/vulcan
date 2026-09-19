# Notifications

A notification records what this application tried to tell someone. It can appear in the notification list, trigger an email or printable letter, or simply preserve communication history.

Audit events record what happened.

Rails flash messages give immediate request feedback.

## The normal flow

1. The workflow calls `NotificationService.create_and_deliver!` with an action, recipient, and related record.
2. The service creates a `Notification`. With `deliver: true`, it attempts the mapped delivery; `deliver: false` creates history only.
3. The mailer builds the message and resolves its destination. Preference-sensitive messages can become letters in the print queue.
4. Routing metadata records the actual channel and reason. A queued message is not proof that the recipient received it.

The requested channel is `:email` or `:letter`, and what happened instead is recorded in `actual_delivery_channel` and `delivery_route_reason` — the requested channel alone will not explain a message that became a letter. SMS never comes from here; specific workflows send it through `SmsService`.

## Which workflow owns delivery?

| Communication | Owner and behavior |
| --- | --- |
| Ordinary notification | [NotificationService](../../app/services/notification_service.rb) creates the row and calls the mapped mailer. |
| Proof approval | `ProofReview` records the audit event and a notification without sending a message. |
| Proof rejection | [RequestProofResubmission](../../app/services/applications/request_proof_resubmission.rb) issues the secure upload request. A failed delivery leaves the review saved and lets staff see a warning. |
| Request for provider details | [RequestProviderInfo](../../app/services/applications/request_provider_info.rb) owns the secure request and delivery. |
| Disability certification | [MedicalCertificationService](../../app/services/applications/medical_certification_service.rb) and [MedicalCertificationReviewer](../../app/services/applications/medical_certification_reviewer.rb) own provider requests and follow-up. Provider delivery can include fax; DocuSeal signing has separate tracking. |
| Security-key recovery approval | Always email, including for users who prefer letters. |
| Account-access SMS | [PasswordsController](../../app/controllers/passwords_controller.rb) sends through `SmsService` and records the outcome in audit events. |

Proof rejection is fenced off: `NotificationService` refuses ordinary `proof_rejected` delivery unless the caller marks itself a legacy path, because the secure-request flow is what actually gives the constituent a way to replace the document. Provider rejection is fenced the same way by omission — there is no generic `medical_certification_rejected` entry in the mailer map, and certification services own that message.

### Record-only actions

`proof_approved`, `medical_certification_received`, `medical_certification_approved`, and `documents_requested` intentionally send nothing. The first three reflect status visible in the portal; `documents_requested` has no delivery mailer.

When delivery is requested for these actions, routing metadata records `none` / `no_email_action`. This is expected behavior.

### Secure-request recipients

[SecureRequestRecipientResolver](../../app/services/applications/secure_request_recipient_resolver.rb) selects the contact owner and channel for provider-info and proof requests. Each new form stores its delivery owner and source, so the issued link retains that history. Resending creates a replacement using current eligible contact details.

The stored owner's supported locale controls messages and public form responses, with a default-locale fallback. Older forms without an owner fall back to the logical recipient; they do not infer a guardian. Letters have no historical address snapshot.

Automatic proof-rejection delivery does not select SMS. Staff can select it from the application detail page when retrying.

## Message content and delivery tracking

[NotificationComposer](../../app/services/notification_composer.rb) supplies short in-app text. Mailers supply full email and letter bodies using [EmailTemplate](../../app/models/email_template.rb). Each template's `syntax` selects `legacy_percent` placeholders or `liquid` with declared variable paths and restricted syntax. Preserve recipient and locale behavior when changing a template.

[UpdateEmailStatusJob](../../app/jobs/update_email_status_job.rb) polls Postmark only for `medical_certification_requested` notifications with a message ID. The webhook handler targets `MedicalProviderEmail`, not `Notification`; see the [email guide](../infrastructure/email_system.md) for that integration's limits. Do not assume every email has delivery or open tracking.

Notification auditing is opt-in through `audit: true`. Normally, leave the domain event with its workflow owner so a single action does not generate duplicate audit history.

## Adding to this

A new mapped action is three things, not one: a recipient contract, a template, and tests that assert what actually went out. Skipping the first produces a mailer that works for the case it was written against and picks the wrong person for dependent applications.

Reset, verification, and upload links are bearer credentials — anything that stores them durably turns a notification row into a way in. [SecureErrorSanitizer](../../app/services/concerns/secure_error_sanitizer.rb) exists because delivery failures otherwise carry the link into the error message, and `sensitive: true` keeps their SMS out of logs.

Recipient, channel, locale, and history are each independently wrong-able, and intentional non-delivery looks identical to broken delivery unless a test distinguishes them. [Notification service tests](../../test/services/notification_service_test.rb), [secure proof-request tests](../../test/services/applications/request_proof_resubmission_test.rb), [delivery locale tests](../../test/services/applications/secure_request_delivery_locale_test.rb), and [webhook tests](../../test/controllers/webhooks/email_events_controller_test.rb) show the shapes.

## Troubleshooting

| Symptom | Check first |
| --- | --- |
| Row exists, no email | Record-only action, `deliver: false`, letter routing, then the mailer map. |
| Proof rejection sent no ordinary email | The secure request and its delivery result; this workflow bypasses ordinary notification delivery. |
| Delivery failed | Delivery status/error metadata, actual route, queued mail job, and provider logs when a message ID exists. |
| Template failed | Template name, format, locale fallback, syntax mode, and declared variables. |

See [proof review](proof_review_process_guide.md), [audit events](audit_event_tracking.md), and the [email system](../infrastructure/email_system.md) for the surrounding workflows.
