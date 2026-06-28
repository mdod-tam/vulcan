# Notification System

This guide explains how MAT Vulcan creates notification records, sends email or printable letters, tracks delivery status, and keeps notification behavior separate from audit history.

It is intentionally higher level than the implementation. Use it to understand ownership, current behavior, and extension rules. For exact method bodies, follow the code paths listed near the end.

---

## 1. What Notifications Are For

Notifications are user-facing communication records. They can also provide persistent history for staff and constituents, even when no message is delivered.

Use the notification system for:

- email or letter delivery
- persistent notification rows shown in `/notifications`
- communication history tied to an application, proof review, training session, vendor, or security workflow
- delivery metadata such as route, failure reason, Postmark message ID, and bounce details

Do not use notifications as a replacement for audit events. Audit events answer "what happened?" Notifications answer "what did we record or try to tell someone?"

Some workflows create both. For example, proof approval logs `proof_approved` as an audit event and creates a record-only `proof_approved` notification.

---

## 2. System Shape

| Area | Current owner |
| --- | --- |
| Notification creation and delivery routing | `NotificationService` |
| Persistent notification state | `Notification` |
| Human-readable notification text | `NotificationComposer` |
| Application and proof mail | `ApplicationNotificationsMailer` |
| Provider certification mail | `MedicalProviderMailer` and certification services |
| Vendor mail | `VendorNotificationsMailer` |
| Training mail | `TrainingSessionNotificationsMailer` |
| Printable letters | recipient-facing mailers and `PrintQueueItem` |
| Email delivery/open tracking | `UpdateEmailStatusJob` and `PostmarkEmailTracker` |
| Bounce/spam webhooks | `Webhooks::EmailEventsController` and `EmailEventHandler` |

The normal entry point is `NotificationService.create_and_deliver!`. It creates a `Notification` row, records delivery intent in metadata, and attempts delivery when `deliver: true`.

`NotificationService.build` also exists for fluent call sites, but most new code should prefer the direct service call unless a builder makes the caller clearer.

---

## 3. Records, Delivery, And Channels

Every notification row has:

- a recipient
- an optional actor
- an optional notifiable record
- an action
- metadata
- read status
- optional delivery status and message ID

The service accepts `:email` and `:letter` as requested channels. That requested channel is not always the final route. Recipient-facing mailers may route a preference-sensitive message to a printable letter when the recipient prefers postal communication.

Important channel details:

- `deliver: false` creates history only. No mailer is enqueued.
- Record-only actions are valid and intentional.
- Email delivery uses ActionMailer jobs for mapped actions.
- Printable letters are represented through the letter/print queue flow.
- SMS is not a general `NotificationService` channel. Selected secure-request services can send SMS through `SmsService`.

---

## 4. Record-Only Notifications

Some actions are intentionally stored without email delivery:

| Action | Why it is record-only |
| --- | --- |
| `proof_approved` | Constituents can see status in the portal; staff need history. |
| `medical_certification_received` | Status is visible in application/certification history. |
| `medical_certification_approved` | Status is visible in application/certification history. |
| `documents_requested` | No mailer delivery path is currently configured. |

For these actions, the service stores routing metadata such as `actual_delivery_channel: "none"` and a reason like `no_email_action`.

Do not treat record-only notifications as failed delivery. They are expected behavior.

---

## 5. Proof Review Communications

Reviewable proof types are income, residency, and ID.

Proof approval behavior:

- `ProofReview` logs `proof_approved`.
- `ProofReview` creates a record-only `proof_approved` notification.
- Individual proof approval email/letter delivery is suppressed today.

Proof rejection behavior:

- `ProofReview` logs the generic `proof_rejected` audit event.
- `Applications::RequestProofResubmission` creates secure upload request tracking.
- Delivery is attempted through the secure request flow, not by sending a bare proof-rejected notification through `NotificationService`.
- If request delivery fails, the proof review remains saved and the admin workflow can show a delivery warning.

`NotificationService` still has legacy proof-rejection action names such as `income_proof_rejected`, `residency_proof_rejected`, and `id_proof_rejected`. Normal code should not use them for reviewable proof rejection delivery. The service blocks those deliveries unless metadata explicitly marks the path as legacy.

---

## 6. Disability Certification Communications

User-facing prose should say disability certification, even though code identifiers still use `medical_certification_*`.

Current certification communication paths include:

| Path | Current behavior |
| --- | --- |
| Provider request email | Certification services create a request notification and enqueue provider email delivery. |
| Secure provider upload request | Tokenized upload services create tracking records and delivery attempts. |
| DocuSeal request | Document signing services and webhooks track signing state separately. |
| Provider rejection follow-up | Certification reviewer and provider notifier handle provider delivery, including fax-first behavior where configured. |
| Printable DCF forms | Admin print queue paths create printable output. |

Provider rejection delivery should stay in the certification-specific services. Do not add a generic `medical_certification_rejected` route to `NotificationService::MAILER_MAP` unless the workflow is deliberately redesigned.

---

## 7. Templates And Message Text

Email templates are stored in the database through `EmailTemplate`.

Template rendering supports:

- `legacy_percent` syntax, such as `%{application_id}`
- `liquid` syntax, such as `{{ application.id }}`, when the `email_template_liquid` flag is enabled

Liquid rendering is intentionally strict. Templates can only reference declared required or optional variable paths. Arbitrary tags and filters are rejected.

`NotificationComposer` generates short human-readable messages for notification rows. Mailers are responsible for full email/letter bodies and template variables.

When adding or changing templates:

- keep the template name aligned with the mailer action
- declare variables explicitly
- preserve locale fallback behavior
- avoid putting sensitive values in long-lived metadata unless they are redacted after delivery

---

## 8. Delivery Tracking

Delivery tracking exists at two levels:

| Tracking type | Current behavior |
| --- | --- |
| Notification routing metadata | Stored after delivery routing, including actual route and reason. |
| Delivery status | Stored on the notification when delivery fails or tracking updates arrive. |
| Postmark polling | `UpdateEmailStatusJob` polls Postmark for `medical_certification_requested` notifications with a `message_id`. |
| Webhooks | Bounce and spam events update matched notification records; matched provider bounces can also create audit events. |

`UpdateEmailStatusJob` only applies to `medical_certification_requested` notifications today. It should not be assumed to track every email sent through the system.

---

## 9. Flash Messages Are Separate

Rails flash messages are request feedback, not persistent notifications.

Use flash messages for:

- form success or failure
- immediate admin feedback
- redirect messages
- validation or workflow warnings shown in the current request

Use `NotificationService` when the system needs a durable communication record or an email/letter delivery attempt.

The older JavaScript toast infrastructure has been removed. Prefer accessible Rails flash behavior for in-app request feedback.

---

## 10. Audit Boundary

`NotificationService` does not create audit events by default.

When callers pass `audit: true`, the service can create notification-level audit events such as notification-created, notification-sent, or notification-failed records. Most domain workflows should leave `audit: false` and let the owning service create the domain audit event.

Examples:

| Workflow | Audit owner | Notification owner |
| --- | --- | --- |
| Proof approval | `ProofReview` logs `proof_approved`. | `ProofReview` creates record-only approval notification. |
| Proof rejection | `ProofReview` logs `proof_rejected`. | Secure resubmission request service creates tracking/delivery records. |
| Application status change | `Application#transition_status!` logs `application_status_changed`. | Notification only if a communication is needed. |
| Medical certification request | Certification service logs certification request/status history. | Notification row and provider mail delivery are request-owned. |

One logical event should have one audit owner and, if needed, one notification owner.

---

## 11. Testing Guidance

Use tests that exercise the workflow owner:

- `NotificationService` tests for service contracts, delivery routing, record-only actions, and legacy proof-rejection blocking
- mailer tests for rendered templates, locale behavior, recipient selection, and letter routing
- controller/service tests for workflows that create notifications as side effects
- webhook/job tests for delivery status updates

Prefer asserting behavior rather than copying implementation internals. Useful assertions include:

- a notification row was created with the expected action and recipient
- `deliver: false` did not enqueue mail
- a record-only action stores `actual_delivery_channel: "none"`
- proof rejection goes through secure proof resubmission instead of bare `NotificationService` delivery
- temporary secrets are redacted after delivery

---

## 12. Troubleshooting

### Notification row exists but no email was sent

Check whether the action is record-only, whether `deliver: false` was used, whether the recipient routes to letter, and whether the mailer map contains the action.

### Proof rejection did not send a normal proof email

That is expected for current reviewable proof rejection. Check secure request forms, delivery result data, and request revocation metadata instead.

### Delivery failed

Check `notification.delivery_status`, `notification.metadata["delivery_error"]`, routing metadata, ActionMailer job logs, and Postmark/webhook logs when the notification has a `message_id`.

### Template rendering failed

Check the template name, format, locale fallback, syntax mode, and declared variables. Liquid templates are strict by design.

---

## 13. Change Rules

When changing notifications:

- Use `NotificationService` for durable notification rows and mapped email/letter delivery.
- Keep proof rejection delivery in `Applications::RequestProofResubmission`.
- Keep disability certification provider delivery in certification-specific services.
- Use `deliver: false` for intentional history-only notifications.
- Leave `audit: false` unless the notification itself is the event being audited.
- Do not add SMS as a generic notification channel without designing a real channel contract.
- Do not add a mailer map entry without a template, recipient contract, and tests.
- Keep secrets out of durable metadata or redact them immediately after delivery.

---

## 14. Where To Look

| Need | Start here |
| --- | --- |
| Notification service behavior | `app/services/notification_service.rb` |
| Notification record behavior | `app/models/notification.rb` |
| In-app notification list | `app/controllers/notifications_controller.rb` |
| Application/proof mail | `app/mailers/application_notifications_mailer.rb` |
| Provider mail | `app/mailers/medical_provider_mailer.rb` |
| Template rendering | `app/models/email_template.rb`, `app/services/email_templates/` |
| Delivery polling | `app/jobs/update_email_status_job.rb`, `app/services/postmark_email_tracker.rb` |
| Bounce/spam handling | `app/controllers/webhooks/email_events_controller.rb`, `app/services/email_event_handler.rb` |
| Proof resubmission delivery | `app/services/applications/request_proof_resubmission.rb` |
| Certification delivery | `app/services/applications/medical_certification_service.rb`, `app/services/applications/medical_certification_reviewer.rb` |

Related docs:

- [Audit Event Tracking](audit_event_tracking.md)
- [Proof Review Process Guide](proof_review_process_guide.md)
- [Application Workflow Guide](application_workflow_guide.md)
- [Email System](../infrastructure/email_system.md)
