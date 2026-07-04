# Email System Guide

MAT Vulcan sends email and generates printable letter content from shared templates. This doc explains **where templates live, how Liquid rendering works, how secure temporary forms collect documents, how letters are generated, and how Postmark is wired up**.

---

## 1 · Template Management

| Aspect | Details |
|--------|---------|
| Storage | `email_templates` DB table |
| Format | Records with `name`, `format` (`:html` / `:text`), `syntax` (`legacy_percent` / `liquid`), `subject`, `body`, `description`, `version` |
| Placeholders | Legacy: `%{first_name}` or `%<first_name>s`. Liquid: `{{ exact.path }}` or trim output tags like `{{- exact.path -}}`. |
| Validation | Required and optional variables are stored in each template's `variables` JSON. Subject/body variables must match those exact paths. Liquid templates may only reference required variables; optional variables remain Standard-only because Liquid rendering is strict. |
| Versioning | `version` increments on subject/body/syntax edits. Subject/body edits store the prior content in `previous_subject`/`previous_body` for the show-page Previous Version panel. |
| Locale sync | `locale_needs_sync` flags counterpart locales out of date; admin UI uses `locale_out_of_sync?` |
| Liquid availability | Liquid syntax is available for text templates. |

Seed/update:

```bash
bin/rails db:seed:email_templates   # or rake db:seed_manual_email_templates
bin/rails email_templates:audit   # read-only: seeds + MAILER_MAP vs DB
```

**Mailer pattern**

```ruby
tpl = EmailTemplate.find_by!(name: 'user_mailer_password_reset', format: :text)
subj, body = tpl.render(user_first_name: @user.first_name, reset_url: ...)
mail(to: @user.email, subject: subj) { format.text { render plain: body } }
```

Password-reset links are bearer links. `UserMailer` builds them with
`CanonicalPublicUrlOptions` so outbound email uses the configured public
host/protocol instead of an inbound request host or the unsafe `example.com`
production fallback. There is no live email-verification link flow in the
current code; public signup currently sends
`ApplicationNotificationsMailer.registration_confirmation`.

**Alternative using class method:**

```ruby
subj, body = EmailTemplate.render('user_mailer_password_reset',
                                  user_first_name: @user.first_name,
                                  reset_url: ...)
```

Admin UI lets staff **edit, preview, and send test mails** — no code deploys for copy changes.

**Available Services:**

* `EmailTemplates::Renderer.render(template:, variables:)` - Shared strict renderer used by `EmailTemplate#render`.
  * `legacy_percent` preserves `%{key}` and `%<key>s` interpolation.
  * `liquid` supports output tags only, rejects `{% %}` tags and filters, and renders only exact allowlisted required paths.
* `EmailTemplate.render_with_tracking(variables, current_user)` - Instance method with audit logging.
* Admin helper: `sample_data_for_template(template_name)` - Provides realistic sample data; Liquid previews omit optional variables so admins see strict-send failures before production.

---

## 2 · Secure Temporary Forms

Incoming document collection now uses secure temporary forms, not inbound email routing.

| Need | Current path |
|------|--------------|
| Rejected or missing income/residency/ID proof | `Applications::RequestProofResubmission` creates a `SecureRequestForm` and delivery is attempted through the selected contact channel. |
| Public proof upload | `Applications::SubmitProofResubmission` validates the token and file, then attaches the document through `ProofAttachmentService`. |
| Disability certification upload option | `Applications::RequestCertificationUpload` creates a provider secure request form. |
| Public disability certification upload | `Applications::SubmitCertificationUpload` validates the token and file, then attaches it through `MedicalCertificationAttachmentService`. |

There is no live `ApplicationMailbox`, `ProofSubmissionMailbox`, or `MedicalCertificationMailbox` path in this checkout. Do not document users, providers, or admins as routing incoming emails for proof or disability certification collection unless those classes and routes are restored.

Secure temporary forms centralize:

* signed token lookup and expiration checks
* revocation of superseded forms
* upload validation through `ProofAttachmentValidator`
* audit events for request, submission, revocation, and expiration
* delivery failure reporting back to the calling workflow

---

## 3 · Letter Generation

Some users choose *physical mail*. The same template renders to PDF using Prawn.

```ruby
Letters::TextTemplateToPdfService
  .new(template_name: 'application_notifications_account_created',
       recipient: user,
       variables: { first_name: user.first_name })
  .queue_for_printing
```

* Uses `EmailTemplate.find_by(name: template_name, format: :text)` for content.
* Renders through `EmailTemplate#render`, so printed letters share the same legacy/Liquid syntax behavior as email.
* Creates `PrintQueueItem` → admin prints from `/admin/print_queue`.
* PDF includes header, date, address, body content, and footer.

---

## 4 · Postmark Setup

### 4.1 Message Streams

| Stream | Purpose |
|--------|---------|
| `outbound` | Auth & transactional (password reset) |
| `notifications` | Status updates, voucher assigned |

Use in mailer:

```ruby
mail(to: user.email, subject: 'Hi', message_stream: 'notifications')
```

### 4.2 Tracking & Webhooks

* `track_opens: true` configured globally in `postmark_format.rb`.
* `UpdateEmailStatusJob` polls Postmark only for `medical_certification_requested` notifications with a `message_id`; do not assume it updates every email-backed `Notification`.
* Bounce events handled by `EmailEventHandler` → creates audit events.
* Webhook endpoint: `/webhooks/email_events` for bounce/complaint notifications.

### 4.3 Debug Logs

```
POSTMARK PAYLOAD (ORIGINAL) # only when POSTMARK_DEBUG_PAYLOADS=true; redacted
POSTMARK PAYLOAD (MODIFIED) # only when POSTMARK_DEBUG_PAYLOADS=true; redacted
POSTMARK SUCCESS / POSTMARK ERROR
```

`config/initializers/postmark_debugger.rb` never logs raw payloads by default.
When payload logging is explicitly enabled, bodies, URLs, and token-bearing
fields are redacted before writing to Rails logs.

---

## 5 · Testing

| Topic | How |
|-------|-----|
| Template render | Mock template → `template.render(**vars)` |
| Secure form flow | Request-service tests plus token submission controller/service tests |
| Letter PDF | Specs for `TextTemplateToPdfService` + `PrintQueueItem` |
| Smoke send | Admin UI “Send test email” |

Example mock (from test helpers):

```ruby
def mock_template(subject_format, body_format)
  template = EmailTemplate.new(
    name: 'test_template',
    format: :text,
    subject: subject_format,
    body: body_format
  )
  template.stubs(:render).returns([subject_format, body_format])
  template
end

# Usage:
tpl = mock_template('Hello %{first_name}', 'Welcome %{first_name}!')
subj, body = tpl.render(first_name: 'Ada')
```

---

## 6 · Troubleshooting Cheatsheet

| Symptom | Check |
|---------|-------|
| **"Template not found"** | Name/format mismatch in DB, run `rake db:seed_manual_email_templates` |
| **Secure form link rejected** | Token expired, revoked, already used, or not active for public use |
| **Secure form upload rejected** | File type/size/content validation in `ProofAttachmentValidator` |
| **Letter generation fails** | Text template exists? all variables supplied? `PrintQueueItem` created? |
| **Wrong stream** | `message_stream` param in mailer (`outbound` vs `notifications`) |
| **Email tracking issues** | `POSTMARK_API_TOKEN`, `UpdateEmailStatusJob` logs, `Notification` records with `action: "medical_certification_requested"` and a `message_id` |
| **Variable validation fails** | Check the template `variables` JSON, exact required/optional paths, and syntax. Liquid placeholders must come from required variables. |

**Tools:**
* Postmark dashboard (delivery & webhooks)
* `/admin/print_queue` (letter generation)
* `/admin/email_templates` (template management and testing)
