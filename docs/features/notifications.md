# Notification System

A comprehensive guide to the notification and communication system in MAT Vulcan, covering email delivery, message composition, template management, and integration patterns across the application.

> **⚠️ Important Distinction**: This document covers the **Notification System** for email communications. For audit trails and event logging, see [`docs/features/audits.md`](./audits.md). The audit system handles system events and data change tracking, while the notification system handles user communications.

---

## 1 · System Overview

### 1.1 · Architecture Components

The notification system is built around a service-oriented architecture with clear separation of concerns:

| Component | Purpose | Usage Pattern |
|-----------|---------|---------------|
| **`NotificationService`** | Central notification orchestration | Used by all services and controllers |
| **`NotificationComposer`** | Message content generation | Used by Notification model and mailers |
| **`Notification` Model** | Notification record storage and tracking | Polymorphic associations to all notifiable entities |
| **Specialized Mailers** | Email template rendering and delivery | Application, Vendor, Medical Provider, Training specific |
| **Email Templates** | Database-stored email content | Dynamic template system with variable substitution |

### 1.2 · Notification Flow Architecture

```
User Action → Service → NotificationService.create_and_deliver!()
                              ↓
                    Notification Record Created
                              ↓
                    Mailer Resolution (MAILER_MAP)
                              ↓
                    Email Template Rendering
                              ↓
                    ActionMailer.deliver_later()
                              ↓
                    Email Delivery (Postmark/SMTP)
```

### 1.3 · Key Features

- **Unified API**: Single service interface for all notification types
- **Template System**: Database-stored email templates with variable substitution
- **Delivery Tracking**: Comprehensive tracking of delivery status and errors
- **Multi-Channel Ready**: Extensible architecture for email, SMS, push notifications
- **Error Recovery**: Robust error handling with retry mechanisms
- **Rails Flash Integration**: Preference for accessible Rails flash messages over toast notifications

### 1.4 · Flash Notifications vs Email Notifications

**MAT Vulcan follows accessibility-first principles and prefers Rails flash notifications for in-app messaging:**

- **✅ Rails Flash Messages**: Preferred for immediate user feedback (form submissions, status updates)
  - More accessible for screen readers and assistive technology
  - Better semantic HTML structure
  - Consistent with Rails conventions
  - Server-rendered, reliable delivery

- **📧 Email Notifications**: Used for important communications that users need outside the application
  - Proof status changes (approved/rejected)
  - Account creation and security updates
  - Medical certification requests
  - Training assignments

**Current State**: The application now uses Rails flash messages exclusively for in-app notifications. All JavaScript toast infrastructure has been removed.

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
    if @proof_review.save
      flash_success("Proof review completed successfully")
      redirect_to admin_application_path(@application)
    else
      flash_error("Unable to complete proof review: #{@proof_review.errors.full_messages.to_sentence}")
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
  type: 'proof_rejected',              # [String] (required) Notification type
  recipient: user,                     # [User] (required) Recipient user
  actor: admin_user,                   # [User] (optional) User performing action
  notifiable: application,             # [ApplicationRecord] (optional) Related object
  metadata: { proof_type: 'income' },  # [Hash] (optional) Additional context
  channel: :email,                     # [Symbol] (optional) Default: :email
  audit: false,                        # [Boolean] (optional) Create audit event
  deliver: true                        # [Boolean] (optional) Actually send email
)
```

**Returns**: `Notification` record or `nil` if failed

#### Builder Pattern (Alternative)

```ruby
NotificationService.build
  .type('proof_approved')
  .recipient(user)
  .actor(admin)
  .notifiable(application)
  .metadata({ proof_type: 'income', notes: 'Looks good!' })
  .channel(:email)
  .audit(true)
  .deliver(true)
  .create_and_deliver!
```

### 2.2 · Notification Types & Mailer Mapping

```ruby
MAILER_MAP = {
  # Application notifications
  'proof_rejected' => [ApplicationNotificationsMailer, :proof_rejected],
  'proof_approved' => [ApplicationNotificationsMailer, :proof_approved],
  'income_proof_rejected' => [ApplicationNotificationsMailer, :proof_rejected],
  'residency_proof_rejected' => [ApplicationNotificationsMailer, :proof_rejected],
  'income_proof_attached' => [ApplicationNotificationsMailer, :proof_received],
  'residency_proof_attached' => [ApplicationNotificationsMailer, :proof_received],
  'account_created' => [ApplicationNotificationsMailer, :account_created],
  
  # Vendor notifications
  'w9_approved' => [VendorNotificationsMailer, :w9_approved],
  'w9_rejected' => [VendorNotificationsMailer, :w9_rejected],
  
  # Training notifications
  'training_requested' => [TrainingSessionNotificationsMailer, :trainer_assigned],
  'trainer_assigned' => [TrainingSessionNotificationsMailer, :trainer_assigned],
  
  # Security notifications
  'security_key_recovery_approved' => [ApplicationNotificationsMailer, :account_created]
}.freeze
```

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
  when 'proof_rejected', 'proof_approved', 'income_proof_rejected', 'residency_proof_rejected'
    # Accept both Application and ProofReview as valid notifiable types
    ensure_action_contract?(notification, notifiable_class: [Application, ProofReview], actor_presence: true)
  when 'account_created'
    ensure_action_contract?(notification, recipient_class: User) &&
    validate_account_created_temp_password?(notification)
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
    metadata.fetch('delivery_error', {}).fetch('message', 'Unknown error')
  end
  
  # Generate human-readable message via NotificationComposer
  def message
    NotificationComposer.generate(action, notifiable, actor, metadata)
  end
end
```

### 3.2 · Database Schema

```sql
CREATE TABLE notifications (
  id BIGINT PRIMARY KEY,
  recipient_id BIGINT NOT NULL,           -- User receiving notification
  actor_id BIGINT,                        -- User who triggered notification
  action VARCHAR NOT NULL,                -- Notification type (e.g., 'proof_approved')
  notifiable_type VARCHAR,                -- Polymorphic type (e.g., 'Application')
  notifiable_id BIGINT,                   -- Polymorphic ID
  metadata JSONB DEFAULT '{}',            -- Additional notification context
  delivery_status VARCHAR DEFAULT 'delivered', -- 'delivered', 'opened', 'error'
  message_id VARCHAR,                     -- Email message ID for tracking
  read_at TIMESTAMP,                      -- When notification was read
  audited BOOLEAN DEFAULT false,          -- Whether audit event was created
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Performance indexes
CREATE INDEX notifications_recipient_id_idx ON notifications (recipient_id);
CREATE INDEX notifications_notifiable_idx ON notifications (notifiable_type, notifiable_id);
CREATE INDEX notifications_action_idx ON notifications (action);
CREATE INDEX notifications_unread_idx ON notifications (recipient_id, read_at) WHERE read_at IS NULL;
CREATE INDEX notifications_metadata_gin_idx ON notifications USING GIN (metadata);
```

### 3.3 · Metadata Structure Examples

```ruby
# Proof rejection notification
{
  "proof_type" => "income",
  "rejection_reason" => "unclear",
  "admin_notes" => "Document is blurry and unreadable",
  "resubmission_allowed" => true,
  "remaining_attempts" => 2
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
  validates :name, presence: true, uniqueness: { scope: :format }
  validates :format, inclusion: { in: %w[text html] }
  validates :subject_template, presence: true
  validates :body_template, presence: true
  
  def render(**variables)
    rendered_subject = ERB.new(subject_template).result_with_hash(variables)
    rendered_body = ERB.new(body_template).result_with_hash(variables)
    [rendered_subject, rendered_body]
  end
end
```

### 5.2 · Template Variable System

Templates use ERB syntax with variable substitution:

```erb
<!-- Subject Template -->
Your <%= proof_type.titleize %> Proof Status - Application #<%= application_id %>

<!-- Body Template -->
Dear <%= user_full_name %>,

Your <%= proof_type.titleize.downcase %> proof for Application #<%= application_id %> has been 
<% if status == 'approved' %>
  ✅ APPROVED
  
  Next steps:
  - Your application will be processed automatically
  - You will receive updates on your application status
<% else %>
  ❌ REJECTED
  
  Reason: <%= rejection_reason %>
  
  <% if resubmission_allowed %>
  You can resubmit your proof by logging into your account:
  <%= login_url %>
  
  Remaining attempts: <%= remaining_attempts %>
  <% end %>
<% end %>

Best regards,
The MAT Vulcan Team
```

### 5.3 · Template Loading & Caching

```ruby
class ApplicationNotificationsMailer < ApplicationMailer
  def proof_rejected(application, proof_review)
    template_name = 'application_notifications_proof_rejected'
    text_template = find_email_template(template_name)
    
    variables = build_proof_rejection_variables(application, proof_review)
    send_email(application.user.email, text_template, variables)
  end
  
  private
  
  def find_email_template(template_name)
    Rails.cache.fetch("email_template_#{template_name}", expires_in: 1.hour) do
      EmailTemplate.find_by!(name: template_name, format: :text)
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
    raise "Email template not found for #{template_name}"
  end
end
```

---

## 6 · Specialized Mailers

### 6.1 · ApplicationNotificationsMailer

Handles all application-related notifications including proof statuses, account creation, and general updates:

```ruby
class ApplicationNotificationsMailer < ApplicationMailer
  include Mailers::ApplicationNotificationsHelper
  include Mailers::SharedPartialHelpers
  
  def proof_approved(application, proof_review)
    handle_proof_approved_letter(application, proof_review)
    
    template_name = 'application_notifications_proof_approved'
    text_template = find_email_template(template_name)
    variables = build_proof_approved_variables(application, proof_review)
    
    send_email(application.user.email, text_template, variables)
  end
  
  def proof_rejected(application, proof_review)
    template_name = 'application_notifications_proof_rejected'
    text_template = find_email_template(template_name)
    variables = build_proof_rejected_variables(application, proof_review)
    
    send_email(application.user.email, text_template, variables)
  end
  
  def account_created(user, temp_password)
    template_name = 'application_notifications_account_created'
    text_template = find_email_template(template_name)
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

### 6.3 · MedicalProviderMailer

Handles medical certification workflow notifications:

```ruby
class MedicalProviderMailer < ApplicationMailer
  def request_certification(application)
    template_name = 'medical_provider_certification_request'
    text_template = load_email_template(template_name)
    variables = build_certification_request_variables(application)
    
    subject, body = text_template.render(**variables)
    send_certification_email(application.medical_provider_email, subject, body)
  end
  
  def certification_approved(application, notification)
    template = load_email_template('medical_provider_certification_approved')
    variables = build_approval_variables(application)
    
    subject, body = template.render(**variables)
    send_approval_email(subject, body)
  end
end
```

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
class ProofReviewService < BaseService
  def call
    ActiveRecord::Base.transaction do
      create_proof_review
      update_application_status
      
      # Send notification
      NotificationService.create_and_deliver!(
        type: "#{@proof_type}_proof_#{@status}",
        recipient: @application.user,
        actor: @admin,
        notifiable: @application,
        metadata: {
          proof_type: @proof_type,
          status: @status,
          rejection_reason: @rejection_reason,
          admin_notes: @notes,
          resubmission_allowed: can_resubmit?,
          remaining_attempts: remaining_attempts
        }
      )
    end
  end
end
```

### 7.2 · Controller Integration

```ruby
class Admin::ApplicationsController < Admin::BaseController
  def update_proof_status
    result = ProofReviewService.new(@application, current_user, params).call
    
    if result.success?
      # Notification sent by service
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
  after_update :notify_status_change, if: :saved_change_to_status?
  
  private
  
  def notify_status_change
    return unless status_approved?
    
    NotificationService.create_and_deliver!(
      type: 'application_approved',
      recipient: user,
      actor: nil, # System action
      notifiable: self,
      metadata: {
        old_status: status_before_last_save,
        new_status: status,
        auto_approval: true
      }
    )
  end
end
```

### 7.4 · Background Job Integration

```ruby
class ApplicationApprovalJob < ApplicationJob
  def perform(application)
    # Send approval notification
    NotificationService.create_and_deliver!(
      type: 'application_approved',
      recipient: application.user,
      notifiable: application,
      metadata: {
        approval_date: Time.current.iso8601,
        next_steps: determine_next_steps(application)
      }
    )
    
    # Send notification to medical provider if needed
    if application.medical_certification_required?
      NotificationService.create_and_deliver!(
        type: 'medical_certification_requested',
        recipient: application.medical_provider,
        notifiable: application,
        metadata: {
          request_type: 'automatic',
          deadline: 30.days.from_now.iso8601
        }
      )
    end
  end
end
```

---

## 8 · Delivery Tracking & Status Management

### 8.1 · Email Tracking Integration

The system integrates with email service providers (like Postmark) to track delivery status:

```ruby
class UpdateEmailStatusJob < ApplicationJob
  def perform(notification_id)
    notification = Notification.find(notification_id)
    return unless notification.email_tracking?
    
    # Query email service provider for status
    status_info = EmailServiceProvider.get_message_status(notification.message_id)
    
    notification.update!(
      delivery_status: map_provider_status(status_info.status),
      metadata: notification.metadata.merge(
        'delivery_info' => status_info.to_h,
        'last_status_check' => Time.current.iso8601
      )
    )
  end
  
  private
  
  def map_provider_status(provider_status)
    case provider_status
    when 'Sent', 'Delivered'
      'delivered'
    when 'Opened'
      'opened'
    when 'Bounced', 'SpamComplaint'
      'error'
    else
      'delivered' # Default
    end
  end
end
```

### 8.2 · Error Handling & Retry Logic

```ruby
def send_notification_email(notification, mailer_class, method_name)
  case notification.action
  when 'account_created'
    temp_password = notification.metadata&.dig('temp_password')
    mailer_class.public_send(method_name, notification.recipient, temp_password).deliver_later
    redact_temp_password(notification)
  when 'proof_rejected', 'proof_approved'
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

```ruby
class BulkNotificationJob < ApplicationJob
  def perform(notification_params_array)
    notifications = []
    
    notification_params_array.each do |params|
      notification = NotificationService.create_and_deliver!(params)
      notifications << notification if notification
    end
    
    Rails.logger.info "BulkNotificationJob: Sent #{notifications.count} notifications"
    notifications
  end
end

# Usage
notification_params = applications.map do |app|
  {
    type: 'deadline_reminder',
    recipient: app.user,
    notifiable: app,
    metadata: { deadline: app.deadline.iso8601 }
  }
end

BulkNotificationJob.perform_later(notification_params)
```

---

## 9 · Testing Patterns

### 9.1 · Service Testing

```ruby
describe NotificationService do
  describe '.create_and_deliver!' do
    it 'creates notification and sends email' do
      expect {
        NotificationService.create_and_deliver!(
          type: 'proof_approved',
          recipient: user,
          actor: admin,
          notifiable: application,
          metadata: { proof_type: 'income' }
        )
      }.to change(Notification, :count).by(1)
      
      notification = Notification.last
      expect(notification.action).to eq('proof_approved')
      expect(notification.recipient).to eq(user)
      expect(notification.metadata['proof_type']).to eq('income')
    end
    
    it 'handles delivery errors gracefully' do
      allow(ApplicationNotificationsMailer).to receive(:proof_approved).and_raise(StandardError)
      
      notification = NotificationService.create_and_deliver!(
        type: 'proof_approved',
        recipient: user,
        notifiable: application
      )
      
      expect(notification.delivery_status).to eq('error')
      expect(notification.metadata['delivery_error']).to be_present
    end
  end
end
```

### 9.2 · Email Template Testing

```ruby
describe 'Email Templates' do
  let(:template) { create(:email_template, :proof_rejection) }
  
  it 'renders template with variables' do
    variables = {
      user_full_name: 'John Doe',
      application_id: 123,
      proof_type: 'income',
      rejection_reason: 'unclear document'
    }
    
    subject, body = template.render(**variables)
    
    expect(subject).to include('Income Proof Status')
    expect(body).to include('John Doe')
    expect(body).to include('unclear document')
  end
end
```

### 9.3 · Integration Testing

```ruby
describe 'Notification Integration' do
  it 'sends notification when proof is approved' do
    expect {
      ProofReviewService.new(application, admin, {
        proof_type: 'income',
        status: 'approved'
      }).call
    }.to change(Notification, :count).by(1)
    
    notification = Notification.last
    expect(notification.action).to eq('income_proof_approved')
    expect(notification.recipient).to eq(application.user)
    
    # Verify email was queued
    expect(ActionMailer::MailDeliveryJob).to have_been_enqueued
  end
end
```

---

## 10 · Performance & Monitoring

### 10.1 · Database Optimization

```sql
-- Essential indexes for notification queries
CREATE INDEX CONCURRENTLY notifications_recipient_unread_idx 
ON notifications (recipient_id, created_at DESC) WHERE read_at IS NULL;

CREATE INDEX CONCURRENTLY notifications_delivery_status_idx 
ON notifications (delivery_status, created_at) WHERE delivery_status = 'error';

CREATE INDEX CONCURRENTLY notifications_action_created_idx 
ON notifications (action, created_at DESC);
```

### 10.2 · Email Template Caching

```ruby
class EmailTemplateCache
  CACHE_DURATION = 1.hour
  
  def self.fetch_template(template_name, format = :text)
    cache_key = "email_template_#{template_name}_#{format}"
    
    Rails.cache.fetch(cache_key, expires_in: CACHE_DURATION) do
      EmailTemplate.find_by!(name: template_name, format: format)
    end
  end
  
  def self.invalidate_template(template_name)
    %w[text html].each do |format|
      Rails.cache.delete("email_template_#{template_name}_#{format}")
    end
  end
end
```

### 10.3 · Monitoring & Alerting

```ruby
class NotificationMonitor
  def self.check_delivery_rates
    failed_notifications = Notification.where(delivery_status: 'error')
                                     .where(created_at: 1.hour.ago..Time.current)
                                     .count
                                     
    total_notifications = Notification.where(created_at: 1.hour.ago..Time.current).count
    
    if total_notifications > 0
      failure_rate = (failed_notifications.to_f / total_notifications * 100).round(2)
      
      if failure_rate > 10.0 # Alert if > 10% failure rate
        alert_administrators("High notification failure rate: #{failure_rate}%")
      end
    end
  end
  
  def self.check_template_errors
    template_errors = Rails.cache.read('email_template_errors') || []
    
    if template_errors.any?
      alert_administrators("Email template errors detected: #{template_errors.join(', ')}")
      Rails.cache.delete('email_template_errors')
    end
  end
end
```

---

## 11 · Configuration & Customization

### 11.1 · Environment Configuration

```ruby
# config/environments/production.rb
config.action_mailer.delivery_method = :postmark
config.action_mailer.postmark_settings = {
  api_token: Rails.application.credentials.postmark_api_token
}

# Enable email tracking
config.notification_service = {
  enable_tracking: true,
  track_opens: true,
  track_clicks: false
}
```

### 11.2 · Custom Notification Types

To add new notification types:

1. **Add to MAILER_MAP**:
```ruby
MAILER_MAP['new_notification_type'] => [YourMailer, :your_method]
```

2. **Create Email Template**:
```ruby
EmailTemplate.create!(
  name: 'your_mailer_new_notification_type',
  format: 'text',
  subject_template: 'Your Custom Subject',
  body_template: 'Your custom email body with <%= variables %>'
)
```

3. **Add NotificationComposer Method**:
```ruby
def message_for_new_notification_type
  "Custom message for #{@notifiable.class.name} ##{@notifiable&.id}"
end
```

### 11.3 · Multi-Channel Extensions

The system is designed to support multiple channels:

```ruby
# Future SMS channel implementation
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

- **Cache email templates** to avoid database queries
- **Use background jobs** for email delivery to avoid blocking requests
- **Batch notifications** when sending to multiple recipients
- **Monitor delivery rates** and set up alerts for failures
- **Archive old notifications** to maintain query performance

### 13.3 · Security Considerations

- **Redact sensitive information** after email delivery (e.g., temporary passwords)
- **Validate recipient permissions** before sending notifications
- **Sanitize template variables** to prevent injection attacks
- **Use secure email headers** to prevent spoofing
- **Implement rate limiting** to prevent abuse

---

**Tools**: Admin notification interface (`/admin/notifications`) · Email template editor (`/admin/email_templates`) · Delivery monitoring (`/admin/notifications/status`) · Template testing (`rails notifications:test_template`)