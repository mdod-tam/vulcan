# Email System Guide

MAT Vulcan delivers, receives, and even prints email content through one unified pipeline. This doc explains **where templates live, how inbound mail is routed, how letters are generated, and how Postmark is wired up**.

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
| Liquid rollout | `email_template_liquid` is seeded off. Liquid templates cannot be saved or rendered while the flag is disabled. |

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

## 2 · Inbound Email

*Rails Action Mailbox + Postmark* handles attachments for proofs & medical certs.

| ENV | Example |
|-----|---------|
| `INBOUND_EMAIL_PROVIDER` | `postmark` |
| `INBOUND_EMAIL_ADDRESS` | `af7e…@inbound.postmarkapp.com` |
| `RAILS_INBOUND_EMAIL_PASSWORD` | webhook token |

Routing (`ApplicationMailbox`):

```text
disability_cert@mdmat.org → MedicalCertificationMailbox
proof@mdmat.org → ProofSubmissionMailbox  
inbound address (env var) → ProofSubmissionMailbox
else → DefaultMailbox
```

Local test:

```bash
bin/test-inbound-emails
ultrahook postmark 3000   # forwards webhooks in dev
```

What users do:

* **Constituent proofs** – email docs to inbound address.  
* **Providers** – email signed certification + app ID in subject.

**Processing Details:**

* `ProofSubmissionMailbox` - Validates constituent, application, rate limits, attachments.
* `MedicalCertificationMailbox` - Validates medical provider, certification request, attachments.
* Both use `before_processing` callbacks that can bounce emails with error notifications.
* Successful processing creates audit events and attaches files to applications.
* Failed processing bounces email and sends error notification to sender.

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
* `UpdateEmailStatusJob` polls Postmark API to update `Notification` delivery status.  
* Bounce events handled by `EmailEventHandler` → creates audit events.
* Webhook endpoint: `/webhooks/email_events` for bounce/complaint notifications.

### 4.3 Debug Logs

```
POSTMARK PAYLOAD (ORIGINAL)
POSTMARK PAYLOAD (MODIFIED)
POSTMARK SUCCESS / POSTMARK ERROR
```

Enable in `config/initializers/postmark_debugger.rb`.

---

## 5 · Testing

| Topic | How |
|-------|-----|
| Template render | Mock template → `template.render(**vars)` |
| Inbound flow | `bin/test-inbound-emails`, Action Mailbox dashboard |
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
| **Inbound mail ignored** | `RAILS_INBOUND_EMAIL_PASSWORD`, routing rules in `ApplicationMailbox` |
| **Inbound mail bounced** | Check constituent exists, has active application, attachment validation |
| **Letter generation fails** | Text template exists? all variables supplied? `PrintQueueItem` created? |
| **Wrong stream** | `message_stream` param in mailer (`outbound` vs `notifications`) |
| **Email tracking issues** | `POSTMARK_API_TOKEN`, `UpdateEmailStatusJob` logs, `Notification` records |
| **Variable validation fails** | Check the template `variables` JSON, exact required/optional paths, syntax, and Liquid flag state. Liquid placeholders must come from required variables. |

**Tools:** 
* Postmark dashboard (delivery & webhooks)
* `/rails/conductor/action_mailbox/inbound_emails` (inbound email processing)
* `/admin/print_queue` (letter generation)
* `/admin/email_templates` (template management and testing)
