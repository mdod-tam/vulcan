# Document Signing Integration for Medical Certification (DocuSeal)

This guide describes the document e-signing integration (DocuSeal) for medical certification workflow. The architecture is service-agnostic, allowing swapping providers without breaking changes.

## Remaining Tasks

- [ ] Review modal: Add "Source: Document Signing" note when applicable
- [ ] Rejection/resend: Admin rejection → `rejected`; keep file; show resend options
- [ ] Provider editing: Inline "Edit/Change Provider" (name/phone/fax/email)
- [ ] Notifications: Decide UI-only vs email; if email, extend MAILER_MAP
- [ ] PDF print channel: Implement `MedicalCertificationPdfService`
- [ ] UX polish: Tooltips for dual status; resend cooldown copy
- [ ] Deployment: Configure webhook, verify S3

---

## 1. Architecture Overview

- **Default channel**: DocuSeal, with email and print (PDF) as backups.
- **Dual Status System**:
  - `document_signing_status` tracks e-signature workflow: `not_sent`, `sent`, `opened`, `signed`, `declined`
  - `medical_certification_status` tracks admin approval: `not_requested`, `requested`, `received`, `approved`, `rejected`
- **Workflow**: Provider signs → `document_signing_status: signed` → Admin reviews → `medical_certification_status: approved`
- **Fallback**: Provider declines → admin can resend or use email/fax

---

## 2. Data Model

### Migration

```ruby
# db/migrate/XXXXXXXXXXXX_add_document_signing_to_applications.rb
change_table :applications, bulk: true do |t|
  t.integer  :document_signing_status, default: 0, null: false
  t.string   :document_signing_service # 'docuseal', 'hellosign', etc.
  t.string   :document_signing_submission_id
  t.string   :document_signing_submitter_id
  t.datetime :document_signing_requested_at
  t.datetime :document_signing_signed_at
  t.integer  :document_signing_request_count, default: 0, null: false
  t.text     :document_signing_audit_url
  t.text     :document_signing_document_url
end

add_index :applications, :document_signing_submission_id
add_index :applications, :document_signing_service
add_index :applications, :document_signing_status
```

### Model Configuration

```ruby
# app/models/application.rb
enum :document_signing_status, {
  not_sent: 0,
  sent: 1,
  opened: 2,
  signed: 3,
  declined: 4
}, prefix: :document_signing_status

encrypts :document_signing_audit_url
encrypts :document_signing_document_url
```

---

## 3. Auto-Approval Policy (Unchanged)

Application auto-approval requires ALL three proof types to be approved. DocuSeal `signed` status does NOT fulfill auto-approval criteria.  An admin must still review and approve.

```ruby
# app/models/concerns/application_status_management.rb
def all_requirements_met?
  income_proof_status_approved? &&
    residency_proof_status_approved? &&
    medical_certification_status_approved?
end
```

---

## 4. Badge Helpers

```ruby
# app/helpers/badge_helper.rb
COLOR_MAPS[:document_signing] = {
  not_sent: 'bg-gray-100 text-gray-800',
  sent: 'bg-yellow-100 text-yellow-800',
  opened: 'bg-blue-100 text-blue-800',
  signed: 'bg-green-100 text-green-800',
  declined: 'bg-red-100 text-red-800',
  default: 'bg-gray-100 text-gray-800'
}
```

```ruby
# app/helpers/application_helper.rb
def document_signing_status_badge(application)
  return nil unless application.document_signing_status.present?
  
  status = application.document_signing_status
  label = case status.to_s
          when 'not_sent' then 'Not Sent'
          when 'sent' then 'Sent for Signing'
          when 'opened' then 'Opened by Provider'
          when 'signed' then 'Signed by Provider'
          when 'declined' then 'Declined by Provider'
          else status.to_s.humanize
          end

  content_tag(:span, label,
              class: "px-2 py-1 text-xs font-medium rounded-full #{badge_class_for(:document_signing, status)}")
end
```

---

## 5. Services

### 5.1 Submission Service

```ruby
# app/services/document_signing/submission_service.rb
module DocumentSigning
  class SubmissionService < BaseService
    def initialize(application:, actor:, service: 'docuseal')
      super()
      @application = application
      @actor = actor
      @service_type = service
    end

    def call
      return failure('Medical provider email is required') if @application.medical_provider_email.blank?
      return failure('Medical provider name is required')  if @application.medical_provider_name.blank?
      return failure('Actor is required')                  if @actor.blank?

      submission = create_submission!
      submitter  = submission['submitters']&.first

      @application.update!(
        document_signing_service: @service_type,
        document_signing_submission_id: submission['id'].to_s,
        document_signing_submitter_id: submitter&.dig('id').to_s,
        document_signing_status: :sent,
        document_signing_requested_at: Time.current,
        document_signing_request_count: @application.document_signing_request_count + 1,
        medical_certification_status: :requested,
        medical_certification_requested_at: Time.current,
        medical_certification_request_count: @application.medical_certification_request_count + 1
      )

      AuditEventService.log(
        action: 'document_signing_request_sent',
        actor: @actor,
        auditable: @application,
        metadata: {
          document_signing_service: @service_type,
          document_signing_submission_id: submission['id'],
          provider_name: @application.medical_provider_name,
          provider_email: @application.medical_provider_email
        }
      )

      success('Document signing request created', submission)
    rescue => e
      log_error(e, application_id: @application.id)
      failure("Failed to create document signing request: #{e.message}")
    end

    private

    def create_submission!
      ::Docuseal.create_submission({
        name: "Medical Certification - App #{@application.id}",
        submitters: [{ role: 'Medical Provider', email: @application.medical_provider_email, name: @application.medical_provider_name }],
        send_email: true,
        completed_redirect_url: Rails.application.routes.url_helpers.admin_application_url(@application, host: Rails.application.config.action_mailer.default_url_options[:host])
      })
    end
  end
end
```

### 5.2 Webhook Controller

```ruby
# app/controllers/webhooks/docuseal_controller.rb
module Webhooks
  class DocusealController < BaseController
    def medical_certification
      event_type = params[:event_type]
      data = params[:data] || {}

      case event_type
      when 'form.viewed'    then handle_viewed(data)
      when 'form.started'   then handle_started(data)
      when 'form.completed' then handle_completed(data)
      when 'form.declined'  then handle_declined(data)
      else Rails.logger.warn "Unknown DocuSeal event: #{event_type}"
      end

      head :ok
    end

    private

    def valid_payload?
      params[:event_type].present?
    end

    def find_application(submission_id)
      Application.find_by(document_signing_submission_id: submission_id.to_s, document_signing_service: 'docuseal')
    end

    def handle_viewed(d)
      return unless (app = find_application(d['submission_id']))
      app.update!(document_signing_status: :opened)
      AuditEventService.log(action: 'document_signing_viewed', actor: nil, auditable: app,
                            metadata: { submission_id: d['submission_id'], provider_email: d['email'] })
    end

    def handle_started(d)
      return unless (app = find_application(d['submission_id']))
      AuditEventService.log(action: 'document_signing_started', actor: nil, auditable: app,
                            metadata: { submission_id: d['submission_id'] })
    end

    def handle_completed(d)
      app = find_application(d['submission_id'])
      return unless app
      return if app.document_signing_status == 'signed' && app.document_signing_document_url.present?

      current_status = app.medical_certification_status.to_s
      attachment_succeeded = current_status != 'approved' && attach_signed_pdf(app, d)
      
      update_attrs = { document_signing_status: :signed, document_signing_signed_at: Time.current }
      update_attrs[:medical_certification_status] = :received if attachment_succeeded && !%w[approved received].include?(current_status)
      app.update!(update_attrs)

      AuditEventService.log(action: 'document_signing_completed', actor: User.system_user, auditable: app,
                            metadata: { submission_id: d['submission_id'], provider_email: d['email'] })
    end

    def attach_signed_pdf(app, d)
      url = d.dig('documents', 0, 'url')
      return false unless url.present?
      return true if app.document_signing_document_url == url

      response = HTTP.timeout(30).get(url)
      return false unless response.status.success?

      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(response.body.to_s),
        filename: "medical_cert_docuseal_#{app.id}.pdf",
        content_type: 'application/pdf'
      )

      app.medical_certification.attach(blob)
      app.update!(document_signing_audit_url: d['audit_log_url'], document_signing_document_url: url)
      true
    rescue => e
      Rails.logger.error "Document signing attach failed for App ##{app.id}: #{e.message}"
      false
    end

    def handle_declined(d)
      return unless (app = find_application(d['submission_id']))
      app.update!(document_signing_status: :declined)
      AuditEventService.log(action: 'document_signing_declined', actor: nil, auditable: app,
                            metadata: { submission_id: d['submission_id'], decline_reason: d['decline_reason'] })
    end
  end
end
```

---

## 6. Routes & Controller Action

```ruby
# config/routes.rb
namespace :admin do
  resources :applications do
    member { post :send_document_signing_request }
  end
end

namespace :webhooks do
  post 'docuseal/medical_certification', to: 'docuseal#medical_certification'
end
```

```ruby
# app/controllers/admin/applications_controller.rb
def send_document_signing_request
  result = DocumentSigning::SubmissionService.new(
    application: @application,
    actor: current_user,
    service: 'docuseal'
  ).call

  if result.success?
    redirect_to admin_application_path(@application), notice: 'Document signing request sent successfully.'
  else
    redirect_to admin_application_path(@application), alert: "Failed: #{result.message}"
  end
end
```

---

## 7. Admin UI

### Buttons (Medical Certification section)

- `not_sent`: "Send DocuSeal Request (Default)"
- `sent/opened`: "Resend DocuSeal (X days since sent)"
- `declined`: "Resend DocuSeal (Provider Declined)"
- `signed`: Show review button if medical cert not yet approved

### Index Page

- Filter: "Digitally Signed (Needs Review)" for `document_signing_status: :signed` + `medical_certification_status` not approved
- Display dual status badges

### Review Modal

- Existing modal config unchanged
- Add "Source: DocuSeal Digital Signature" note when applicable

### Rejection Behavior

- Admin rejection sets `medical_certification_status: :rejected`
- Document signing status remains `signed` for audit trail
- Keep signed file attached

---

## 8. Notifications (Optional)

Start with UI-based visibility (index filter + badges). For email alerts:

```ruby
# app/services/notification_service.rb
MAILER_MAP = MAILER_MAP.merge(
  'document_signing_completed' => [ApplicationNotificationsMailer, :document_signing_admin_alert]
).freeze
```

---

## 9. PDF Print Channel

Use existing Prawn patterns from:
- `app/services/letters/text_template_to_pdf_service.rb`
- `app/services/medical_provider_notifier.rb`

Create `MedicalCertificationPdfService` that queues to PrintQueue or streams directly.

---

## 10. Configuration

### Gemfile

```ruby
gem 'docuseal'
gem 'http'
```

### Initializer

```ruby
# config/initializers/docuseal.rb
Rails.application.configure do
  config.after_initialize do
    if Rails.application.credentials.docuseal.present?
      ::Docuseal.key = Rails.application.credentials.docuseal[:api_key]
      ::Docuseal.url = Rails.application.credentials.docuseal[:base_url] || 'https://api.docuseal.com'
    end
  end
end
```

### Credentials

```yaml
# credentials.yml.enc
docuseal:
  api_key: <your_key>
  base_url: https://api.docuseal.com
```

---

## 11. Testing

- **Unit**: `DocumentSigning::SubmissionService` success/failure paths
- **Integration**: Webhook events update status/attachments; signature verification
- **System**: Admin sends request; reviews signed certification

Stub DocuSeal API calls with WebMock.

---

## 12. UX Guidelines

- Use "Digitally Signed" (not "DocuSeal") in user-facing text
- Show dual badges: primary (medical cert) + secondary (signing status)
- Display "Last sent X days ago" for resend cooldown context
- Tooltips explaining `signed` ≠ auto-approved

---

## Go-Live Checklist

1. **Add credentials**
   ```bash
   EDITOR="code --wait" bin/rails credentials:edit
   ```
   
2. **Run migration**
   ```bash
   bin/rails db:migrate
   ```

3. **Configure DocuSeal webhook**
   - URL: `https://yourdomain.com/webhooks/docuseal/medical_certification`
   - Events: `form.viewed`, `form.started`, `form.completed`, `form.declined`

4. **Deploy and verify**:
   - [ ] Credentials configured
   - [ ] Migration applied
   - [ ] Webhook registered in DocuSeal dashboard
   - [ ] End-to-end test: admin sends → provider signs → admin reviews

### Rollback

```bash
bin/rails db:rollback
git revert <commit-hash>
```
