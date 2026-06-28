# Notification System

A comprehensive guide to the notification and communication system in MAT Vulcan, covering email delivery, message composition, template management, and integration patterns across the application.

> **⚠️ Important Distinction**: This document covers the **Notification System** for email communications. For audit trails and event logging, see [`docs/features/audit_event_tracking.md`](./audit_event_tracking.md). The audit system handles system events and data change tracking, while the notification system handles user communications.

---

## 1 · System Overview

### 1.1 · Architecture Components

The notification system is built around a service-oriented architecture with clear separation of concerns:

| Component | Purpose | Usage Pattern |
|-----------|---------|---------------|
| **`NotificationService`** | Central notification orchestration | Used by all services and controllers |
| **`NotificationComposer`** | Message content generation | Used by Notification model and mailers |
| **`Notification` Model** | Notification record storage and tracking | Polymorphic associations to all notifiable entities |
| **Specialized Mailers** | Email template rendering and delivery | Application, Vendor, Training, and provider-specific paths |
| **Email Templates** | Database-stored email content | `legacy_percent` and `liquid` syntax with strict variable validation |

### 1.2 · Notification Flow Architecture

```text
User Action -> Service or model callback -> NotificationService.create_and_deliver!()
                                      |
                                      v
                              Notification row
                                      |
                 deliver: false or NOOP action? -> record-only
                                      |
                                      v
                           Mailer resolution (MAILER_MAP)
                                      |
                                      v
                       ActionMailer.deliver_later / letter queue
```

### 1.3 · Key Features

- **Unified API**: Single service interface for all notification types
- **Template System**: Database-stored email templates with `legacy_percent` and Liquid rendering
- **Delivery Tracking**: Comprehensive tracking of delivery status and errors
- **Delivery Channels Today**: Email delivery is implemented; selected workflows can also queue printable letters.
- **Error Recovery**: Robust error handling with retry mechanisms
- **Rails Flash Integration**: Preference for accessible Rails flash messages over toast notifications

### 1.4 · Flash Notifications vs Email Notifications

**MAT Vulcan follows accessibility-first principles and prefers Rails flash notifications for in-app messaging:**

- **✅ Rails Flash Messages**: Preferred for immediate user feedback (form submissions, status updates)
  - More accessible for screen readers and assistive technology
  - Better semantic HTML structure
  - Consistent with Rails conventions
  - Server-rendered, reliable delivery

- **📧 Email or Letter Notifications**: Used for important communications that users need outside the application
  - Proof resubmission requests after rejected reviewable proofs
  - Account creation and security updates
  - Disability certification requests
  - Training assignments

**Current State**: The application uses Rails flash messages for request feedback and `Notification` records for persistent notification history. JavaScript toast infrastructure has been removed.

### 1.5 · Flash Notification Implementation

**Controller Pattern for Flash Messages:**

```ruby
class ApplicationController < ActionController::Base
  private
  
   # Extended flash types configured via add_flash_types
   def flash_success(message)
     flash[:success] = message
   end
   
   def flash_error(message)
     flash[:error] = message
   end
   
   def flash_warning(message)
     flash[:warning] = message
   end
   
   def flash_info(message)
     flash[:info] = message
   end
end

# Usage in controllers
class ProofReviewController < Admin::BaseController
  def update
    result = ProofReviewService.new(@application, current_user, params).call

    if result.success?
      flash_success("Proof review completed successfully")
      redirect_to admin_application_path(@application)
    else
      flash_error("Unable to complete proof review: #{result.message}")
      render :show
    end
  end
end
```

**View Template Pattern:**

```erb
<!-- app/views/shared/_flash.html.erb -->
<% if flash.any? %>
  <div class="flash-messages" aria-live="polite">
    <% flash.each do |type, message| %>
      <div role="alert" class="flash-message flash-<%= type %> mb-4 <%= flash_class_for(type) %>" data-testid="flash-<%= type %>">
        <%= message %>
      </div>
    <% end %>
  </div>
<% end %>
```

**Accessibility Features:**
- `role="alert"` for immediate screen reader announcement
- `aria-live="polite"` for non-intrusive updates
- `aria-label` for dismiss buttons
- Semantic color coding with icons
- Keyboard navigation support

---

## 2 · NotificationService - Central Orchestrator

### 2.1 · Core API

#### Primary Method: `create_and_deliver!`

```ruby
NotificationService.create_and_deliver!(
  type: 'medical_certification_not_provided', # [String] (required) Notification type
  recipient: user,                     # [User] (required) Recipient user
  actor: admin_user,                   # [User] (optional) User performing action
  notifiable: application,             # [ApplicationRecord] Related object; pass one for normal records
  metadata: { proof_type: 'income' },  # [Hash] (optional) Additional context
  channel: :email,                     # [Symbol] (optional) Default: :email
  audit: false,                        # [Boolean] (optional) Create audit event
  deliver: true                        # [Boolean] (optional) Actually send email
)
```

**Returns**: `Notification` record or `nil` if failed

If `audit: true`, `NotificationService` uses `AuditEventService.log()` to write an `Event` record with action `notification_<action>_created`, `_sent`, or `_failed` depending on whether delivery was requested and whether it succeeded. The default is `audit: false`; callers that already write a domain audit event should leave notification auditing off.

#### Builder Pattern (Alternative)

```ruby
NotificationService.build
  .type('proof_approved')
  .recipient(user)
  .actor(admin)
  .notifiable(application)
  .metadata({ proof_type: 'income', notes: 'Looks good!' })
  .channel(:email)
  .audit(false)
  .deliver(false)
  .create_and_deliver!
```

### 2.2 · Notification Types & Mailer Mapping

```ruby
MAILER_MAP = {
  # Application notifications
  'proof_rejected' => [ApplicationNotificationsMailer, :proof_rejected],
  'id_proof_rejected' => [ApplicationNotificationsMailer, :proof_rejected],
  'income_proof_rejected' => [ApplicationNotificationsMailer, :proof_rejected],
  'residency_proof_rejected' => [ApplicationNotificationsMailer, :proof_rejected],
  'id_proof_attached' => [ApplicationNotificationsMailer, :proof_received],
  'income_proof_attached' => [ApplicationNotificationsMailer, :proof_received],
  'residency_proof_attached' => [ApplicationNotificationsMailer, :proof_received],
  'account_created' => [ApplicationNotificationsMailer, :account_created],
  'medical_certification_requested' => [MedicalProviderMailer, :requested],
  'medical_certification_not_provided' => [ApplicationNotificationsMailer, :medical_certification_not_provided],
  'max_rejections_warning' => [ApplicationNotificationsMailer, :max_rejections_reached],
  
  # Vendor notifications
  'w9_approved' => [VendorNotificationsMailer, :w9_approved],
  'w9_rejected' => [VendorNotificationsMailer, :w9_rejected],
  
  # Training notifications
  'training_requested' => [ApplicationNotificationsMailer, :training_requested],
  'trainer_assigned' => [TrainingSessionNotificationsMailer, :trainer_assigned],
  'training_scheduled' => [TrainingSessionNotificationsMailer, :training_scheduled],
  'training_rescheduled' => [TrainingSessionNotificationsMailer, :training_rescheduled],
  'training_cancelled' => [TrainingSessionNotificationsMailer, :training_cancelled],
  'training_missed' => [TrainingSessionNotificationsMailer, :no_show_notification],
  
  # Security notifications
  'security_key_recovery_approved' => [ApplicationNotificationsMailer, :security_key_recovery_approved]
}.freeze
```

`proof_approved`, `medical_certification_received`, `medical_certification_approved`, and `documents_requested` are intentionally record-only `NOOP_DELIVERY_ACTIONS`. Reviewable proof rejections are normally delivered by `Applications::RequestProofResubmission`; bare `NotificationService` proof-rejection delivery is blocked unless metadata includes `delivery_path: 'legacy'`.

### 2.3 · Error Handling & Recovery

```ruby
def create_and_deliver!(type:, recipient:, **options)
  opts = normalize_options(options)
  build_notification_builder(type, recipient, opts).create_and_deliver!
rescue StandardError => e
  calling_location = e.backtrace_locations&.find { |loc| !loc.path.match?(%r{app/services/notification_service}) }
  caller_info = calling_location ? "Called from #{calling_location.path}:#{calling_location.lineno}" : 'Caller unknown'
  error_type = e.is_a?(ArgumentError) ? 'invalid argument(s)' : 'unexpected error'
  
  Rails.logger.error "NotificationService: Failed to create notification (type: #{type}) due to #{error_type}: #{e.message}. #{caller_info}"
  nil
end
```

### 2.4 · Delivery Contracts & Validation

The service enforces contracts for specific notification types:

```ruby
def enforce_delivery_contracts!(notification)
  case notification.action
  when 'proof_rejected', 'id_proof_rejected', 'income_proof_rejected', 'residency_proof_rejected'
    # Accept both Application and ProofReview as valid notifiable types
    ensure_action_contract?(notification, notifiable_class: [Application, ProofReview], actor_presence: true)
  when 'account_created'
    ensure_action_contract?(notification, recipient_class: User)
  when 'medical_certification_not_provided'
    ensure_action_contract?(notification, notifiable_class: Application, actor_presence: true)
  else
    true # No specific contract for other actions
  end
end
```

---

## 3 · Notification Model & Database

### 3.1 · Model Structure

```ruby
class Notification < ApplicationRecord
  attr_accessor :delivery_successful

  enum :delivery_status, { delivered: 'delivered', opened: 'opened', error: 'error' }, suffix: true
  
  belongs_to :recipient, class_name: 'User'
  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :notifiable, polymorphic: true, optional: true
  
  validates :action, presence: true
  
  # Scopes
  scope :unread_notifications, -> { where(read_at: nil) }
  scope :read_notifications, -> { where.not(read_at: nil) }
  scope :medical_certification_requests, -> { where(action: 'medical_certification_requested') }
  
  def mark_as_read!
    update!(read_at: Time.current)
  end
  
  def email_tracking?
    message_id.present?
  end
  
  def check_email_status!
    return unless email_tracking?
    UpdateEmailStatusJob.perform_later(id)
  end
  
  def email_error_message
    return nil unless delivery_status == 'error'
    return 'Unknown error' unless metadata.is_a?(Hash)

    metadata.fetch('delivery_error', {}).fetch('message', 'Unknown error')
  end
  
  def update_metadata!(key, value)
    with_lock do
      new_metadata = metadata || {}
      new_metadata[key.to_s] = value
      update!(metadata: new_metadata)
    end
  end

  # Generate human-readable message via NotificationComposer
  def message(viewer = nil)
    NotificationComposer.generate(action, notifiable, actor, metadata, viewer: viewer)
  end

  def proof_resubmission_rejected?
    action == 'proof_resubmission_requested' &&
      self.class.proof_resubmission_rejected_metadata?(metadata)
  end
end
```

**Note**: Both the model and database schema allow optional `actor`/`notifiable` associations. `NotificationService` provides a `default_actor` fallback when needed and enforces specific contracts via `enforce_delivery_contracts!` for notification types that require these associations.

### 3.2 · Database Schema

```sql
CREATE TABLE notifications (
  id BIGINT PRIMARY KEY,
  recipient_id BIGINT NOT NULL,           -- User receiving notification
  actor_id BIGINT,                        -- User who triggered notification (optional)
  action VARCHAR,                         -- Notification type (validated by model)
  notifiable_type VARCHAR NOT NULL,       -- Polymorphic type (e.g., 'Application')
  notifiable_id BIGINT,                   -- Polymorphic ID (optional)
  metadata JSONB,                         -- Additional notification context
  delivery_status VARCHAR,                -- 'delivered', 'opened', 'error'
  message_id VARCHAR,                     -- Email message ID for tracking
  read_at TIMESTAMP,                      -- When notification was read
  delivered_at TIMESTAMP,                 -- When delivery was confirmed
  opened_at TIMESTAMP,                    -- When recipient opened the email
  audited BOOLEAN DEFAULT false NOT NULL, -- Whether audit event was created
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Performance indexes
CREATE INDEX index_notifications_on_recipient_id ON notifications (recipient_id);
CREATE INDEX index_notifications_on_actor_id ON notifications (actor_id);
CREATE INDEX index_notifications_on_notifiable ON notifications (notifiable_type, notifiable_id);
CREATE INDEX index_notifications_on_message_id ON notifications (message_id);
CREATE INDEX index_notifications_on_audited ON notifications (audited);
```

**Schema Design**: `actor_id` and `notifiable_id` are nullable. The model declares `actor` and `notifiable` as optional, but the current schema still requires `notifiable_type`; in practice, callers should pass a notifiable record for normal application notifications.

### 3.3 · Metadata Structure Examples

```ruby
# Proof resubmission tracking notification
{
  "secure_request_form_id" => 123,
  "application_id" => 456,
  "recipient_id" => 789,
  "recipient_channel" => "email",
  "request_batch_id" => "uuid",
  "proof_type" => "income",
  "proof_request_display_mode" => "rejected",
  "rejection_reason" => "Document is blurry and unreadable",
  "expires_at" => "2026-01-15T10:30:00Z"
}

# Account creation notification
{
  "temp_password" => "SecureTemp123!", # Redacted after email sent
  "login_url" => "https://app.example.com/sign_in",
  "password_expires_at" => "2024-01-15T10:30:00Z"
}

# Training assignment notification
{
  "training_session_id" => 456,
  "constituent_name" => "John Doe",
  "training_type" => "assistive_technology",
  "scheduled_date" => "2024-01-20"
}
```

---

## 4 · NotificationComposer - Message Generation

### 4.1 · Purpose & Architecture

The `NotificationComposer` provides a centralized service for generating user-facing notification messages, decoupling message content from the Notification model.

```ruby
class NotificationComposer
  include ActionView::Helpers::TextHelper # For helpers like pluralize
  
  def self.generate(notification_action, notifiable, actor = nil, metadata = {})
    new(notification_action, notifiable, actor, metadata).generate
  end
  
  def generate
    method_name = "message_for_#{@action}"
    if respond_to?(method_name, true)
      send(method_name)
    else
      default_message
    end
  end
end
```

### 4.2 · Message Generation Methods

```ruby
def message_for_proof_rejected
  proof_type = @metadata['proof_type']&.titleize || 'Proof'
  reason = @metadata['rejection_reason']
  reason_text = reason.present? ? " - #{reason}" : ''
  
  "#{proof_type} rejected for application ##{@notifiable&.id}#{reason_text}."
end

def message_for_proof_approved
  proof_type = @metadata['proof_type']&.titleize || 'Proof'
  "#{proof_type} approved for application ##{@notifiable&.id}."
end

def message_for_trainer_assigned
  trainer_name = @actor&.full_name || 'A trainer'
  application = @notifiable
  constituent_name = application.try(:constituent_full_name) || 'a constituent'
  
  training_session = find_training_session(application, @actor)
  status_info = training_session ? " (#{training_session.status.humanize})" : ''
  
  "#{trainer_name} assigned to train #{constituent_name} for Application ##{@notifiable&.id}#{status_info}."
end

def message_for_medical_certification_requested
  "Medical certification requested for application ##{@notifiable&.id}"
end
```

### 4.3 · Default Message Fallback

```ruby
def default_message
  "#{@action.humanize} notification regarding #{@notifiable.class.name} ##{@notifiable&.id}."
end
```

---

## 5 · Email Template System

### 5.1 · Database-Stored Templates

Email templates are stored in the database via the `EmailTemplate` model, allowing for dynamic content management:

```ruby
class EmailTemplate < ApplicationRecord
  enum :format, { html: 0, text: 1 }
  enum :syntax, { legacy_percent: 0, liquid: 1 }

  validates :name, presence: true, uniqueness: { scope: :format }
  validates :subject, presence: true
  validates :body, presence: true
  validates :format, presence: true
  validates :description, presence: true
  validates :version, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  
  # Delegates to EmailTemplates::Renderer, which enforces syntax and variables.
  def render(**variables)
    EmailTemplates::Renderer.render(template: self, variables: variables)
  end
end
```

### 5.2 · Template Variable System

Templates support two syntax modes:

- `legacy_percent`: `%{variable}` and `%<variable>s`
- `liquid`: output tags such as `{{ application.id }}` or `{{- application.id -}}`

Liquid rendering is current behavior when `email_template_liquid` is enabled. It is intentionally strict: templates can only reference exact required or optional variable paths declared on the template, and Liquid tags/filters are rejected.

```text
<!-- Subject Template -->
Your %{proof_type_formatted} Proof Status - Application #%{application_id}

<!-- Body Template -->
Dear %{user_full_name},

Your %{proof_type_formatted} proof for Application #%{application_id} has been %{status_text}.

Reason: %{rejection_reason}

You can resubmit your proof by logging into your account:
%{login_url}

Best regards,
The MAT Vulcan Team
```

### 5.3 · Template Loading & Caching

```ruby
class ApplicationNotificationsMailer < ApplicationMailer
  def proof_rejected(application, proof_review, secure_upload_url: nil, recipient: nil)
    recipient   ||= application.user
    remaining_attempts = 8 - application.total_rejections
    reapply_date = 3.years.from_now.to_date
    template_name = 'application_notifications_proof_rejected'
    locale        = resolve_template_locale(recipient: recipient)
    text_template = find_text_template(template_name, locale: locale)

    variables = build_proof_rejected_variables(
      application,
      proof_review,
      remaining_attempts,
      reapply_date,
      secure_upload_url,
      recipient,
      template: text_template,
      locale: locale
    )
    send_email(recipient_email_for(recipient), text_template, variables)
  end
end

# find_text_template lives on ApplicationMailer — inherited by all mailers.
# It looks up (name, format: :text, locale) and falls back to I18n.default_locale.
```

---

## 6 · Specialized Mailers

### 6.1 · ApplicationNotificationsMailer

Handles application-related notifications including proof resubmission requests, account creation, training requests, and disability-certification follow-up. Proof approval notifications are record-only through `NotificationService`; approval mail/letters are intentionally suppressed today.

```ruby
class ApplicationNotificationsMailer < ApplicationMailer
  include Mailers::ApplicationNotificationsHelper
  include Mailers::SharedPartialHelpers
  
  def proof_rejected(application, proof_review, secure_upload_url: nil, recipient: nil)
    template_name = 'application_notifications_proof_rejected'
    recipient   ||= application.user
    remaining_attempts = 8 - application.total_rejections
    reapply_date = 3.years.from_now.to_date
    locale        = resolve_template_locale(recipient: recipient)
    text_template = find_text_template(template_name, locale: locale)
    variables = build_proof_rejected_variables(
      application,
      proof_review,
      remaining_attempts,
      reapply_date,
      secure_upload_url,
      recipient,
      template: text_template,
      locale: locale
    )
    
    send_proof_rejected_email(recipient, text_template, variables)
  end
  
  def account_created(user, temp_password)
    template_name = 'application_notifications_account_created'
    locale        = resolve_template_locale(recipient: user)
    text_template = find_text_template(template_name, locale: locale)
    variables = build_account_created_variables(user, temp_password)
    
    send_email(user.email, text_template, variables)
  end
end
```

### 6.2 · VendorNotificationsMailer

Handles vendor-specific notifications including W9 status updates, invoice generation, and payment notifications:

```ruby
class VendorNotificationsMailer < ApplicationMailer
  include ActionView::Helpers::NumberHelper # For number_to_currency
  
  def w9_approved(vendor)
    variables = build_w9_variables(vendor, :success, 'W9 Form Approved', 'W9 Approved')
    subject, body = render_template('vendor_notifications_w9_approved', variables)
    
    send_mail(vendor.email, subject, body)
  end
  
  def invoice_generated(invoice)
    vendor = invoice.vendor
    transactions = invoice.voucher_transactions.includes(:voucher)
    
    variables = build_invoice_variables(invoice, vendor, transactions)
    subject, body = render_template('vendor_notifications_invoice_generated', variables)
    
    # Attach PDF invoice
    attachments["invoice-#{invoice.invoice_number}.pdf"] = generate_invoice_pdf(invoice, vendor, transactions)
    
    send_mail(vendor.email, subject, body)
  end
end
```

### 6.3 · Disability Certification Provider Delivery

Disability certification requests and rejection follow-up are provider-facing workflows. Code identifiers still use `medical_certification_*`, but user-facing prose should say disability certification.

Current provider rejection behavior:

- A record-only constituent notification can be created for visibility.
- Provider delivery is handled by `Applications::MedicalCertificationReviewer` and `MedicalProviderNotifier`, not by routing a `medical_certification_rejected` notification through `NotificationService::MAILER_MAP`.
- `MedicalProviderNotifier` attempts the configured provider channel, including fax-first behavior where applicable and email fallback when available.
- Notification failures should be surfaced to admins without undoing the underlying review record.

### 6.4 · TrainingSessionNotificationsMailer

Handles training-related notifications:

```ruby
class TrainingSessionNotificationsMailer < ApplicationMailer
  def trainer_assigned(training_session)
    template_name = 'training_session_notifications_trainer_assigned'
    text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    
    variables = build_trainer_assignment_variables(training_session)
    subject, body = text_template.render(**variables)
    
    send_training_email(training_session.trainer.email, subject, body)
  end
end
```

---

## 7 · Integration Patterns

### 7.1 · Service Integration

```ruby
class ProofReview < ApplicationRecord
  after_commit :handle_post_review_actions, on: :create

  private

  # Proof approval/rejection callbacks own audit and notification side effects.
  # Rejections call Applications::RequestProofResubmission so the constituent
  # receives a secure upload request instead of a generic proof email.
  # Approvals log proof_approved and create a record-only proof_approved notification.
end
```

### 7.2 · Controller Integration

```ruby
class Admin::ApplicationsController < Admin::BaseController
  def update_proof_status
    result = ProofReviewService.new(@application, current_user, params).call
    
    if result.success?
      # ProofReview callbacks create the domain audit/notification records.
      # Rejected reviews may also include result.data[:resubmission_delivered].
      redirect_to admin_application_path(@application), notice: 'Review completed'
    else
      render :show, alert: result.message
    end
  end
end
```

### 7.3 · Model Callback Integration

```ruby
class Application < ApplicationRecord
  def transition_status!(new_status, actor:, notes: nil, metadata: {})
    with_lock do
      old_status = status
      update!(status: new_status)

      status_changes.create!(
        from_status: old_status,
        to_status: status,
        user: actor,
        notes: notes,
        metadata: metadata.reverse_merge(application_id: id)
      )

      AuditEventService.log(
        action: 'application_status_changed',
        actor: actor,
        auditable: self,
        metadata: metadata.reverse_merge(old_status: old_status, new_status: status)
      )
    end
  end
end
```

### 7.4 · Background Job Integration

Notifications are delivered via `ActionMailer#deliver_later` inside `NotificationService` for mapped notification types. Disability certification request email status tracking is handled by `UpdateEmailStatusJob`.

---

## 8 · Delivery Tracking & Status Management

### 8.1 · Email Tracking Integration

The system uses `PostmarkEmailTracker` + `UpdateEmailStatusJob` to track delivery status for
`medical_certification_requested` notifications:

```ruby
class UpdateEmailStatusJob < ApplicationJob
  def perform(notification_id)
    notification = Notification.find(notification_id)
    return unless notification.email_tracking?
    
    status = PostmarkEmailTracker.fetch_status(notification.message_id)
    
    notification.update!(
      delivery_status: status[:status],
      delivered_at: status[:delivered_at],
      opened_at: status[:opened_at]
    )
  end
end
```

`UpdateEmailStatusJob` currently applies only to `medical_certification_requested` notifications.

**Disability Certification Tracking**: Disability certification audit events (tracked via `AuditEventService.log()`) include `submission_method` metadata to identify the delivery channel: `email`, `secure_form`, `mail` (postal), or `document_signing` (electronic). See [`docs/features/audit_event_tracking.md`](./audit_event_tracking.md) for complete details.

### 8.2 · Error Handling & Retry Logic

```ruby
def send_notification_email(notification, mailer_class, method_name)
  case notification.action
  when 'account_created'
    temp_password = notification.metadata&.dig('temp_password')
    mailer_class.public_send(method_name, notification.recipient, temp_password).deliver_later
    redact_temp_password(notification)
  when 'proof_rejected', 'id_proof_rejected', 'income_proof_rejected', 'residency_proof_rejected'
    application = notification.notifiable
    proof_review = find_proof_review(application, notification.metadata)
    mailer_class.public_send(method_name, application, proof_review).deliver_later
  else
    # Generic notification handling
    mailer_class.public_send(method_name, notification.notifiable, notification).deliver_later
  end
rescue StandardError => e
  handle_delivery_error(notification, e, :email)
  raise
end

def handle_delivery_error(notification, error, channel)
  error_metadata = {
    'delivery_error' => {
      'message' => error.message,
      'class' => error.class.name,
      'timestamp' => Time.current.iso8601,
      'channel' => channel.to_s
    }
  }
  
  notification.update!(
    delivery_status: 'error',
    metadata: notification.metadata.merge(error_metadata)
  )
  
  Rails.logger.error "NotificationService: Delivery failed for #{notification.action} notification ##{notification.id}: #{error.message}"
end
```

### 8.3 · Batch Operations & Performance

Batch notification jobs are not currently implemented. If we add a bulk job, it should
call `NotificationService.create_and_deliver!` for each payload and preserve audit metadata.

---

## 9 · Testing Patterns

### 9.1 · Service Testing

```ruby
test 'creates record-only proof approval notification' do
  assert_difference('Notification.count', 1) do
    NotificationService.create_and_deliver!(
      type: 'proof_approved',
      recipient: user,
      actor: admin,
      notifiable: application,
      metadata: { proof_type: 'income' }
    )
  end

  notification = Notification.last
  assert_equal 'proof_approved', notification.action
  assert_equal user, notification.recipient
  assert_equal 'none', notification.metadata['actual_delivery_channel']
  assert_equal 'no_email_action', notification.metadata['delivery_route_reason']
  assert_nil notification.delivery_status
end

test 'handles delivery errors gracefully' do
  ApplicationNotificationsMailer.stub(:medical_certification_not_provided, ->(*) { raise StandardError }) do
    notification = NotificationService.create_and_deliver!(
      type: 'medical_certification_not_provided',
      recipient: user,
      actor: admin,
      notifiable: application
    )

    assert_equal 'error', notification.delivery_status
    assert notification.metadata['delivery_error'].present?
  end
end
```

### 9.2 · Email Template Testing

```ruby
test 'renders template with variables' do
  template = create(:email_template, :proof_rejection)
  variables = {
    user_full_name: 'John Doe',
    application_id: 123,
    proof_type_formatted: 'Income',
    rejection_reason: 'unclear document'
  }

  subject, body = template.render(**variables)

  assert_includes subject, 'Income'
  assert_includes body, 'John Doe'
  assert_includes body, 'unclear document'
end
```

### 9.3 · Integration Testing

```ruby
test 'records notification when proof is approved' do
  assert_difference('Notification.count', 1) do
    ProofReviewService.new(application, admin, {
      proof_type: 'income',
      status: 'approved'
    }).call
  end

  notification = Notification.last
  assert_equal 'proof_approved', notification.action
  assert_equal application.user, notification.recipient
  assert_equal 'none', notification.metadata['actual_delivery_channel']
  assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob
end
```

---

## 10 · Performance & Monitoring

### 10.1 · Database Optimization

```sql
-- Existing indexes (from schema.rb)
CREATE INDEX index_notifications_on_recipient_id ON notifications (recipient_id);
CREATE INDEX index_notifications_on_actor_id ON notifications (actor_id);
CREATE INDEX index_notifications_on_notifiable ON notifications (notifiable_type, notifiable_id);
CREATE INDEX index_notifications_on_message_id ON notifications (message_id);
CREATE INDEX index_notifications_on_audited ON notifications (audited);

-- Optional indexes (not currently present)
-- CREATE INDEX notifications_delivery_status_idx ON notifications (delivery_status, created_at);
-- CREATE INDEX notifications_unread_idx ON notifications (recipient_id, read_at) WHERE read_at IS NULL;
```

### 10.2 · Email Template Caching

Templates are fetched directly from the database in mailers via `ApplicationMailer#find_text_template` (inherited by `ApplicationNotificationsMailer` and other mailers).
If caching is added, it should be keyed by template name + format and invalidated on update.

### 10.3 · Monitoring & Alerting

There is no dedicated `NotificationMonitor` class. Delivery failures are logged by `NotificationService`
and stored in `notification.metadata['delivery_error']`. Postmark tracking updates `delivery_status`,
`delivered_at`, and `opened_at` via `UpdateEmailStatusJob`. Bounce/complaint webhooks are handled by
`Webhooks::EmailEventsController` + `EmailEventHandler`.

---

## 11 · Configuration & Customization

### 11.1 · Environment Configuration

```ruby
# config/application.rb
config.action_mailer.delivery_method = :postmark
config.action_mailer.postmark_settings = {
  api_token: Rails.application.credentials.postmark_api_token
}
```

### 11.2 · Custom Notification Types

To add new notification types:

1. **Add to MAILER_MAP**:
```ruby
MAILER_MAP['new_notification_type'] = [YourMailer, :your_method]
```

2. **Create Email Template**:
```ruby
EmailTemplate.create!(
  name: 'your_mailer_new_notification_type',
  format: :text,
  subject: 'Your Custom Subject',
  body: 'Your custom email body with %{variables}',
  description: 'Short description of the template',
  version: 1,
  enabled: true
)
```

3. **Add NotificationComposer Method**:
```ruby
def message_for_new_notification_type
  "Custom message for #{@notifiable.class.name} ##{@notifiable&.id}"
end
```

### 11.3 · Multi-Channel Extensions

`NotificationService::VALID_CHANNELS` currently allows `:email` and `:letter`. Recipient-facing mailers decide whether a preference-routed message becomes email or a queued printable letter. SMS delivery exists in selected secure-request services through `SmsService`; it is not a general `NotificationService` channel.

Example pseudo-code (not currently in codebase):

```ruby
class SmsChannel
  def self.deliver(notification)
    SmsService.send_message(
      to: notification.recipient.phone_number,
      message: NotificationComposer.generate(
        notification.action,
        notification.notifiable,
        notification.actor,
        notification.metadata
      )
    )
  end
end

# Add to NotificationService
CHANNEL_HANDLERS = {
  email: EmailChannel,
  sms: SmsChannel,
  push: PushNotificationChannel
}.freeze
```

---

## 12 · Troubleshooting

### 12.1 · Common Issues

**Problem**: Notifications not being sent  
**Diagnosis**:
```ruby
# Check if notification was created
notification = Notification.where(action: 'target_action').last
puts "Notification created: #{notification.present?}"
puts "Delivery status: #{notification&.delivery_status}"

# Check mailer mapping
mailer_info = NotificationService::MAILER_MAP['target_action']
puts "Mailer mapping: #{mailer_info}"

# Check email template
template = EmailTemplate.find_by(name: "mailer_target_action")
puts "Template exists: #{template.present?}"
```

**Problem**: Template rendering errors  
**Solution**:
```ruby
# Test template rendering
template = EmailTemplate.find_by!(name: 'template_name')
variables = { user_name: 'Test', application_id: 123 }

begin
  subject, body = template.render(**variables)
  puts "Rendering successful"
rescue StandardError => e
  puts "Template error: #{e.message}"
  puts "Available variables: #{variables.keys}"
end
```

### 12.2 · Performance Issues

**Problem**: Slow notification queries  
**Solution**:
```ruby
# Add missing indexes
ActiveRecord::Migration.add_index :notifications, [:recipient_id, :created_at]
ActiveRecord::Migration.add_index :notifications, [:action, :created_at]

# Optimize queries
notifications = user.notifications
                   .includes(:actor, :notifiable)
                   .order(created_at: :desc)
                   .limit(50)
```

---

## 13 · Best Practices

### 13.1 · Notification Design Guidelines

- **Use clear, actionable language** in notification messages
- **Include relevant context** in metadata for future reference
- **Provide next steps** when appropriate (e.g., resubmission links)
- **Respect user preferences** for notification frequency and types
- **Test email rendering** across different email clients

### 13.2 · Performance Best Practices

- **Consider caching email templates** if query volume grows
- **Use background jobs** for email delivery to avoid blocking requests
- **Batch notifications** only after introducing a bulk job
- **Monitor delivery rates** and set up alerts for failures
- **Archive old notifications** to maintain query performance

### 13.3 · Security Considerations

- **Redact sensitive information** after email delivery (e.g., temporary passwords)
- **Validate recipient permissions** before sending notifications
- **Sanitize template variables** to prevent injection attacks
- **Use secure email headers** to prevent spoofing
- **Implement rate limiting** to prevent abuse

---

**Tools**: Notifications index (`/notifications`) · Email template editor (`/admin/email_templates`) · Postmark dashboard for delivery monitoring
