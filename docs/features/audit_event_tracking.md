# Audit & Event Tracking System

A comprehensive guide to the audit trail and event tracking system in MAT Vulcan, providing complete visibility into user actions, system operations, and data changes throughout the application lifecycle.

This document covers the **Audit & Event System** for tracking data changes and system operations. For user communications and email notifications, see [`docs/features/notifications.md`](./notifications.md).

---

## 1 · System Overview

### 1.1 · Architecture Components

The audit system consists of multiple interconnected services and models that work together to provide comprehensive event tracking:

| Component | Purpose | Usage Pattern |
|-----------|---------|---------------|
| **`AuditEventService`** | Central event logging with deduplication | Used by all services and controllers |
| **`EventDeduplicationService`** | Advanced deduplication for display | Used by audit log builders |
| **`Applications::AuditLogBuilder`** | Aggregates events from multiple sources | Used by admin interfaces |
| **`Applications::EventService`** | Application-specific event creation | Used for dependent/guardian events |
| **`Event` Model** | Core audit record storage | Polymorphic associations to all auditable models |
| **`Authentications::EventsController`** | User event viewing interface | Displays user's own events |

### 1.2 · Audit vs Notification System

**Clear Separation of Concerns:**

| System | Purpose | When to Use | Examples |
|--------|---------|-------------|----------|
| **🔍 Audit System** | Track what happened | Data changes, user actions, system events | `proof_approved`, `application_created`, `user_login` |
| **📧 Notification System** | Communicate with users | Email alerts, status updates | Email when proof approved, account creation emails |

**Key Principle**: Audit events create permanent records for compliance and debugging. Notifications communicate important information to users. Some actions trigger both (e.g., proof approval creates an audit event AND sends an email notification).

### 1.3 · Event Flow Architecture

```
User Action → Controller → Service → AuditEventService.log() → Event Record
                    ↓
             Model Callbacks → Additional Events (if needed)
                    ↓
          EventDeduplicationService → Consolidated View
                    ↓
             AuditLogBuilder → Admin Display
```

### 1.4 · Key Principles

- **Single Source of Truth**: `AuditEventService` is the canonical way to create audit events
- **Deduplication**: Multiple layers prevent duplicate events while preserving legitimate variations
- **Context Awareness**: Events capture user context, IP addresses, and system state
- **Polymorphic Design**: Single Event model handles all auditable entities
- **Performance Optimized**: Efficient querying and aggregation for large audit trails

---

## 2 · Core Audit Services

### 2.1 · Service Responsibilities

| Service | File | Primary Responsibility |
|---------|------|----------------------|
| **`AuditEventService`** | `app/services/audit_event_service.rb` | Creates and deduplicates audit events |
| **`Applications::AuditLogBuilder`** | `app/services/applications/audit_log_builder.rb` | Aggregates events from multiple sources for display |
| **`Applications::EventService`** | `app/services/applications/event_service.rb` | Creates application-specific events (dependent/guardian) |
| **`EventDeduplicationService`** | `app/services/applications/event_deduplication_service.rb` | Advanced deduplication for admin displays |

### 2.2 · Model & Controller Components

| Component | File | Purpose |
|-----------|------|---------|
| **`Event` Model** | `app/models/event.rb` | Core audit record storage with polymorphic associations |
| **`Authentications::EventsController`** | `app/controllers/authentications/events_controller.rb` | User interface for viewing their own events |

---

## 3 · AuditEventService - Central Event Logger

### 3.1 · Core API

#### Primary Method: `log`

```ruby
AuditEventService.log(
  action: 'proof_approved',              # [String] (required) Action identifier
  actor: current_user,                   # [User] (required) User performing action
  auditable: application,                # [ApplicationRecord] (required) Target object
  metadata: { proof_type: 'income' },   # [Hash] (optional) Additional context
  created_at: Time.current               # [Time] (optional) Timestamp override for testing
)
```

**Returns**: `Event` record or `nil` if deduplicated

### 3.2 · Deduplication Logic

The service includes sophisticated deduplication to prevent duplicate events:

```ruby
# Time-based deduplication window
DEDUP_WINDOW = 5.seconds

# Fingerprinting for proof events includes specific metadata
def create_event_fingerprint(action, metadata)
  base = action.to_s
  
  # For proof events, include proof_type and submission_method
  if action.include?('proof_submitted') || action.include?('proof_attached')
    proof_type = metadata['proof_type'] || metadata[:proof_type]
    submission_method = metadata['submission_method'] || metadata[:submission_method]
    blob_id = metadata['blob_id'] || metadata[:blob_id]
    
    # Include blob_id for attachment events to ensure one event per attachment
    if action.include?('proof_attached') && blob_id
      return "#{base}_#{proof_type}_blob_#{blob_id}"
    elsif proof_type && submission_method
      return "#{base}_#{proof_type}_#{submission_method}"
    end
  end
  
  base
end
```

### 3.3 · Context Capture

Events automatically capture contextual information:

```ruby
# Event attributes passed to Event.create!
event_attributes = {
  user: actor,
  action: action.to_s,
  auditable: auditable,
  metadata: metadata.reverse_merge(__service_generated: true)
}

# Note: ip_address and user_agent are stored as columns on Event and are
# populated automatically via a before_create callback using Current attributes.
```

### 3.4 · Error Handling

```ruby
begin
  event = Event.create!(event_attributes)
rescue ActiveRecord::RecordInvalid => e
  Rails.logger.error "AuditEventService: Failed to log event: #{e.message}"
  Rails.logger.error "Event attributes: #{event_attributes.inspect}"
  raise # Re-raise to make visible in tests
end
```

---

## 4 · Event Model & Database Schema

### 4.1 · Model Structure

```ruby
class Event < ApplicationRecord
  belongs_to :user                                    # Actor who performed the action
  belongs_to :auditable, polymorphic: true, optional: true  # Target object
  
  validates :action, presence: true
  validate :validate_metadata_structure
  
  # Automatic context capture
  before_create do
    self.user_agent = Current.user_agent
    self.ip_address = Current.ip_address
  end
  
  # Ensure metadata is always a hash
  def metadata
    super || {}
  end
  
  # Scope for metadata queries
  scope :with_metadata, lambda { |key, value|
    where('metadata @> ?', { key => value }.to_json)
  }
end
```

### 4.2 · Database Schema

```sql
CREATE TABLE events (
  id BIGINT PRIMARY KEY,
  user_id BIGINT NOT NULL,                    -- Actor (references users table)
  action VARCHAR NOT NULL,                    -- Action identifier (e.g., 'proof_approved')
  auditable_type VARCHAR,                     -- Polymorphic type (e.g., 'Application')
  auditable_id BIGINT,                        -- Polymorphic ID
  metadata JSONB DEFAULT '{}' NOT NULL,       -- Additional event context
  ip_address VARCHAR,                         -- User's IP address
  user_agent VARCHAR,                         -- User's browser/client
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Existing indexes
CREATE INDEX events_auditable_idx ON events (auditable_type, auditable_id);
CREATE INDEX events_user_id_idx ON events (user_id);
CREATE INDEX events_metadata_gin_idx ON events USING GIN (metadata);

-- (Optional indexes, not currently present)
-- CREATE INDEX CONCURRENTLY events_action_idx ON events (action);
-- CREATE INDEX CONCURRENTLY events_created_at_idx ON events (created_at);
-- CREATE INDEX CONCURRENTLY events_auditable_action_idx ON events (auditable_type, auditable_id, action);
```

### 4.3 · Metadata Structure Examples

```ruby
# Proof attachment event
{
  "proof_type" => "income",
  "submission_method" => "web",
  "status" => "not_reviewed",
  "has_attachment" => true,
  "blob_id" => 123,
  "blob_size" => 1024000,
  "filename" => "proof.pdf",
  "success" => true,
  "__service_generated" => true
}

# Application status change
{
  "old_status" => "in_progress",
  "new_status" => "approved",
  "auto_approval" => true,
  "trigger" => "proof_income_approved",
  "__service_generated" => true
}

# Medical certification request
{
  "medical_provider_email" => "doctor@clinic.com",
  "request_type" => "automatic",
  "application_id" => 456,
  "__service_generated" => true
}
```

---

## 5 · EventDeduplicationService - Advanced Deduplication

### 5.1 · Purpose & Architecture

The `EventDeduplicationService` provides sophisticated deduplication for displaying audit trails, handling events from multiple sources (Events, Notifications, ApplicationStatusChanges, ProofReviews).

```ruby
class EventDeduplicationService < BaseService
  # Time window for grouping events
  DEDUPLICATION_WINDOW = 1.minute
  
  # Deduplicates events from various sources
  def deduplicate(events)
    grouped_events = events.group_by do |event|
      [
        event_fingerprint(event),
        (event.created_at.to_i / DEDUPLICATION_WINDOW) * DEDUPLICATION_WINDOW
      ]
    end
    
    # Select best event from each group
    grouped_events.values.map { |group| select_best_event(group) }
                          .sort_by(&:created_at)
                          .reverse
  end
end
```

### 5.2 · Fingerprinting Strategy

```ruby
def event_fingerprint(event)
  # Never deduplicate application_created events
  return "application_created_#{event.id}" if event.action == 'application_created'
  
  action = generic_action(event)
  details = fingerprint_details(event)
  [action, details].compact.join('_')
end

def fingerprint_details(event)
  case event
  when ApplicationStatusChange
    "#{event.from_status}-#{event.to_status}"
  when ProofReview
    "#{event.proof_type}-#{event.status}"
  when Event
    if event.action.include?('proof_submitted')
      "#{event.metadata['proof_type']}-#{event.metadata['submission_method']}"
    end
  end
end
```

### 5.3 · Priority System

Events are prioritized when selecting the best representative from duplicates:

```ruby
def priority_score(event)
  # Application creation events get highest priority
  return 4 if event.respond_to?(:action) && event.action == 'application_created'
  
  case event
  when ApplicationStatusChange
    3  # Highest priority for status changes
  when ProofReview, Event
    2  # Medium priority for reviews and events
  when Notification
    1  # Lowest priority for notifications
  else
    0  # Unknown types
  end
end
```

---

## 6 · Common Event Types & Actions

### 6.1 · Application Events

| Action | Triggered By | Metadata Keys |
|--------|-------------|---------------|
| `application_created` | Application submission | `submission_method`, `initial_status` |
| `application_auto_approved` | System auto-approval | `old_status`, `new_status`, `trigger` |
| `application_status_changed` | Admin status update | `old_status`, `new_status`, `notes` |

### 6.2 · Proof Events

| Action | Triggered By | Metadata Keys |
|--------|-------------|---------------|
| `income_proof_attached` | ProofAttachmentService | `proof_type`, `submission_method`, `blob_id`, `filename` |
| `residency_proof_attached` | ProofAttachmentService | `proof_type`, `submission_method`, `blob_id`, `filename` |
| `proof_submitted` | Tracking submission (paper/web/email) | `proof_type`, `submission_method`, `email_from`, `blob_id` |
| `proof_approved` | Admin review (ProofReview) | `proof_type`, `admin_id`, `review_notes` |
| `proof_rejected` | Admin review (ProofReview) | `proof_type`, `rejection_reason`, `admin_id` |
| `income_proof_rejected` | Explicit reject path without attachment | `proof_type`, `rejection_reason`, `admin_id` |

### 6.3 · Medical Certification Events

| Action | Triggered By | Metadata Keys |
|--------|-------------|---------------|
| `medical_certification_requested` | System auto-request | `medical_provider_email`, `request_type` |
| `medical_certification_received` | Email processing | `submission_method`, `email_from` |
| `medical_certification_approved` | Admin review | `admin_id`, `review_notes` |
| `medical_certification_rejected` | Admin review | `rejection_reason`, `admin_id` |

### 6.4 · User & Authentication Events

| Action | Triggered By | Metadata Keys |
|--------|-------------|---------------|
| `user_login` | Authentication | `login_method`, `ip_address`, `user_agent` |
| `user_logout` | Session end | `session_duration` |
| `password_changed` | Password update | `change_method` |
| `two_factor_enabled` | 2FA setup | `method_type` |

Note: These are examples of potential events. They are not currently emitted by the codebase unless otherwise noted in controller logic.

### 6.5 · Administrative Events

| Action | Triggered By | Metadata Keys |
|--------|-------------|---------------|
| `admin_note_added` | Admin interface | `note_content`, `application_id` |
| `bulk_action_performed` | Admin bulk operations | `action_type`, `affected_count` |
| `policy_updated` | System configuration | `policy_name`, `old_value`, `new_value` |

---

## 7 · AuditLogBuilder - Event Aggregation

### 6.1 · Purpose & Usage

The `AuditLogBuilder` aggregates events from multiple sources to provide comprehensive audit trails for admin interfaces:

```ruby
# Usage in controllers
audit_builder = Applications::AuditLogBuilder.new(application)
@audit_logs = audit_builder.build_deduplicated_audit_logs

# Returns combined and deduplicated events from:
# - Event records
# - ApplicationStatusChange records  
# - ProofReview records
# - Notification records
```

### 6.2 · Event Source Integration

```ruby
def combined_events
  [
    load_proof_reviews,           # ProofReview model events
    load_status_changes,          # ApplicationStatusChange events
    load_notifications,           # Notification events
    load_application_events,      # Direct Event records
    load_user_profile_changes     # User modification events
  ].flatten
end

def build_creation_event
  # Synthetic event for application creation
  Event.new(
    user: application.user,
    auditable: application,
    action: 'application_created',
    created_at: application.created_at,
    metadata: {
      'submission_method' => application.submission_method,
      'initial_status' => application.status
    }
  )
end
```

### 6.3 · Performance Optimization

```ruby
# Efficient eager loading
def load_proof_reviews
  application.proof_reviews
             .includes(:admin)  # Avoid N+1 queries
             .order(:created_at)
end

# Scoped queries to reduce data transfer
def load_application_events
  Event.where(auditable: application)
       .includes(:user)
       .order(:created_at)
end
```

---

## 7 · Integration Patterns

### 7.1 · Controller Integration

```ruby
class Admin::ApplicationsController < Admin::BaseController
  def update_proof_status
    # Business logic
    result = ProofReviewService.new(@application, current_user, params).call
    
    if result.success?
      # Audit event is created by the service
      redirect_to admin_application_path(@application)
    else
      # Error handling
      render :show, alert: result.message
    end
  end
  
  private
  
  # Set Current attributes for context capture
  def set_current_attributes
    Current.set(request, current_user)
  end
end
```

### 7.2 · Service Integration

```ruby
class ProofReviewService < BaseService
  def call
    ActiveRecord::Base.transaction do
      # Business logic
      create_proof_review
      update_application_status
      
      # Audit event
      AuditEventService.log(
        action: "#{@proof_type}_proof_#{@status}",
        actor: @admin,
        auditable: @application,
        metadata: {
          proof_type: @proof_type,
          status: @status,
          rejection_reason: @rejection_reason,
          admin_notes: @notes
        }
      )
    end
    
    success(message: "Proof review completed")
  end
end
```

### 7.3 · Model Callback Integration

```ruby
class Application < ApplicationRecord
  # Use callbacks sparingly - prefer service-layer auditing
  after_update :log_status_change, if: :saved_change_to_status?
  
  private
  
  def log_status_change
    # Skip if currently in a guard context to prevent recursive calls
    return if @logging_status_change

    acting_user = Current.user || user # Ensure a user is always present
    return if acting_user.blank?
    
    @logging_status_change = true
    
    begin
      AuditEventService.log(
        action: 'application_status_changed',
        actor: acting_user,
        auditable: self,
        metadata: {
          old_status: status_before_last_save,
          new_status: status,
          change_source: 'model_callback'
        }
      )
    ensure
      @logging_status_change = false
    end
  end
end
```

---

## 8 · Context Management

### 8.1 · Current Attributes

The audit system uses Rails' `Current` attributes to capture contextual information:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :paper_context, :resubmitting_proof, :skip_proof_validation
  attribute :reviewing_single_proof, :force_notifications, :test_user_id
  attribute :user, :request_id, :user_agent, :ip_address
  attribute :proof_attachment_service_context

  def paper_context? = paper_context.present?
  def resubmitting_proof? = resubmitting_proof.present?
  def skip_proof_validation? = skip_proof_validation.present?
  def reviewing_single_proof? = reviewing_single_proof.present?
  def force_notifications? = force_notifications.present?
  def proof_attachment_service_context? = proof_attachment_service_context.present?

  class << self
    def set(request, user)
      self.user_agent = request.user_agent
      self.ip_address = request.remote_ip
      self.user = user
    end
  end
end
```

### 8.2 · Context Usage Patterns

```ruby
# Setting context in controllers
before_action :set_current_attributes

def set_current_attributes
  Current.user = current_user
  Current.ip_address = request.remote_ip
  Current.user_agent = request.user_agent
end

# Other contexts are used for specific flows, e.g. ProofAttachmentService toggles
# `Current.proof_attachment_service_context` while it handles audit events itself.
```

### 8.3 · Preventing Duplicate Events

```ruby
# ProofAttachmentService uses skip_audit_events parameter to control event creation
ProofAttachmentService.call(
  application: application,
  proof_type: :income,
  blob_or_file: file,
  submission_method: :web,
  admin: current_user,
  skip_audit_events: true  # Admin controller handles its own audit events
)

# Within ProofAttachmentService
def log_audit_event(context, event_metadata)
  return if context.skip_audit_events
  
  AuditEventService.log(
    action: "#{context.proof_type}_proof_attached",
    actor: context.admin,
    auditable: context.application,
    metadata: event_metadata
  )
end

# Current attributes are used to prevent model callback conflicts
def some_proof_related_callback
  return if Current.proof_attachment_service_context?
  
  # Create audit event only if service isn't handling it
  AuditEventService.log(...)
end
```

---

## 9 · Querying & Reporting

### 9.1 · Basic Queries

```ruby
# All events for an application
events = Event.where(auditable: application).includes(:user).order(:created_at)

# Events by action type
proof_events = Event.where(action: ['income_proof_attached', 'residency_proof_attached'])

# Events with specific metadata
failed_uploads = Event.with_metadata('success', false)

# Events in date range
recent_events = Event.where(created_at: 1.week.ago..Time.current)
```

### 9.2 · Advanced Metadata Queries

```ruby
# PostgreSQL JSONB queries
# Events with specific proof type
income_events = Event.where("metadata @> ?", { proof_type: 'income' }.to_json)

# Events with nested metadata conditions
admin_actions = Event.where("metadata ->> 'admin_id' IS NOT NULL")

# Complex metadata filtering
bulk_actions = Event.where("metadata ->> 'action_type' = 'bulk' AND (metadata ->> 'affected_count')::int > 10")
```

### 9.3 · Reporting Queries

```ruby
# Daily event counts by type
daily_stats = Event.group(:action)
                  .group_by_day(:created_at)
                  .count

# User activity summary
user_activity = Event.joins(:user)
                    .group('users.email')
                    .group(:action)
                    .count

# Failed operation analysis
failures = Event.with_metadata('success', false)
               .group(:action)
               .group("metadata ->> 'error_type'")
               .count
```

---

## 10 · Performance Considerations

### 10.1 · Database Optimization

```sql
-- Essential indexes for performance
CREATE INDEX CONCURRENTLY events_auditable_action_idx 
ON events (auditable_type, auditable_id, action);

CREATE INDEX CONCURRENTLY events_created_at_desc_idx 
ON events (created_at DESC);

CREATE INDEX CONCURRENTLY events_user_action_idx 
ON events (user_id, action);

-- GIN index for metadata queries
CREATE INDEX CONCURRENTLY events_metadata_gin_idx 
ON events USING GIN (metadata);
```

### 10.2 · Query Optimization

```ruby
# Efficient event loading with includes
def load_audit_trail(application)
  Event.where(auditable: application)
       .includes(:user)  # Prevent N+1 queries
       .order(created_at: :desc)
       .limit(100)  # Pagination for large trails
end

# Batch processing for bulk operations
def create_bulk_events(events_data)
  Event.insert_all(events_data.map { |data|
    data.merge(created_at: Time.current, updated_at: Time.current)
  })
end
```

### 10.3 · Memory Management

```ruby
# Stream large result sets
def export_events(date_range)
  Event.where(created_at: date_range)
       .find_each(batch_size: 1000) do |event|
    yield event  # Process one at a time
  end
end

# Efficient aggregation
def event_summary(application)
  Event.where(auditable: application)
       .group(:action)
       .count
       # Returns hash without loading individual records
end
```

---

## 11 · Testing Patterns

### 11.1 · Event Creation Testing

```ruby
describe 'Event Creation' do
  it 'creates audit event for proof approval' do
    expect {
      AuditEventService.log(
        action: 'income_proof_approved',
        actor: admin_user,
        auditable: application,
        metadata: { proof_type: 'income' }
      )
    }.to change(Event, :count).by(1)
    
    event = Event.last
    expect(event.action).to eq('income_proof_approved')
    expect(event.metadata['proof_type']).to eq('income')
  end
  
  it 'prevents duplicate events within deduplication window' do
    # Create first event
    AuditEventService.log(
      action: 'income_proof_attached',
      actor: user,
      auditable: application,
      metadata: { proof_type: 'income', blob_id: 123 }
    )
    
    # Attempt duplicate
    expect {
      AuditEventService.log(
        action: 'income_proof_attached',
        actor: user,
        auditable: application,
        metadata: { proof_type: 'income', blob_id: 123 }
      )
    }.not_to change(Event, :count)
  end
end
```

### 11.2 · Context Testing

```ruby
describe 'Context Management' do
  it 'captures current user context' do
    Current.user = admin_user
    Current.ip_address = '192.168.1.1'
    Current.user_agent = 'Test Browser'
    
    event = AuditEventService.log(
      action: 'test_action',
      actor: admin_user,
      auditable: application
    )
    
    expect(event.ip_address).to eq('192.168.1.1')
    expect(event.user_agent).to eq('Test Browser')
  end
  
  it 'respects proof_attachment_service_context flag' do
    Current.proof_attachment_service_context = true
    
    expect {
      # Code that would normally create events but should be skipped
      # when the service is handling audit events itself
      application.some_proof_related_callback
    }.not_to change(Event, :count)
  end
end
```

### 11.3 · Integration Testing

```ruby
describe 'Full Audit Trail' do
  it 'creates complete audit trail for application lifecycle' do
    # Application creation
    application = create(:application)
    
    # Proof submissions
    ProofAttachmentService.attach_proof(
      application: application,
      proof_type: :income,
      blob_or_file: fixture_file_upload('proof.pdf'),
      submission_method: :web,
      admin: user
    )
    
    # Admin review
    ProofReviewService.new(application, admin, {
      proof_type: 'income',
      status: 'approved'
    }).call
    
    # Verify complete trail
    events = Event.where(auditable: application).order(:created_at)
    expect(events.map(&:action)).to include(
      'application_created',
      'income_proof_attached',
      'income_proof_approved'
    )
  end
end
```

---

## 12 · Monitoring & Alerting

### 12.1 · Event Volume Monitoring

```ruby
# Monitor event creation rates
class EventVolumeMonitor
  def check_event_rates
    current_hour_events = Event.where(created_at: 1.hour.ago..Time.current).count
    
    if current_hour_events > ALERT_THRESHOLD
      alert_administrators("High event volume: #{current_hour_events} events in last hour")
    end
  end
  
  def check_failed_events
    failed_events = Event.with_metadata('success', false)
                        .where(created_at: 1.hour.ago..Time.current)
                        .count
                        
    if failed_events > FAILURE_THRESHOLD
      alert_administrators("High failure rate: #{failed_events} failed events")
    end
  end
end
```

### 12.2 · Audit Integrity Checks

```ruby
class AuditIntegrityChecker
  def check_missing_events
    # Verify critical events exist for all applications
    applications_without_creation_events = Application.left_joins(:events)
                                                     .where(events: { id: nil })
                                                     
    if applications_without_creation_events.any?
      alert_administrators("Missing creation events for #{applications_without_creation_events.count} applications")
    end
  end
  
  def check_orphaned_events
    # Find events referencing non-existent records
    orphaned_events = Event.where.not(auditable_id: nil)
                          .where.not(auditable_type: nil)
                          .includes(:auditable)
                          .where(auditable: nil)
                          
    if orphaned_events.any?
      alert_administrators("Found #{orphaned_events.count} orphaned events")
    end
  end
end
```

---

## 13 · Troubleshooting

### 13.1 · Missing Events

**Problem**: Expected audit events are not being created  
**Diagnosis**:
```ruby
# Check if deduplication is suppressing events
recent_events = Event.where(action: 'target_action')
                    .where(created_at: 5.seconds.ago..Time.current)
                    
# Check Current attribute flags
puts "Service context: #{Current.proof_attachment_service_context?}"

# Verify actor and auditable are valid
puts "Actor valid: #{actor&.persisted?}"
puts "Auditable valid: #{auditable&.persisted?}"
```

### 13.2 · Duplicate Events

**Problem**: Multiple similar events being created  
**Solution**:
```ruby
# Check fingerprinting logic
action = 'income_proof_attached'
metadata = { proof_type: 'income', blob_id: 123 }
fingerprint = AuditEventService.create_event_fingerprint(action, metadata)
puts "Fingerprint: #{fingerprint}"

# Verify deduplication window
existing_events = Event.where(action: action, auditable: auditable)
                      .where(created_at: 5.seconds.ago..Time.current)
puts "Recent similar events: #{existing_events.count}"
```

### 13.3 · Performance Issues

**Problem**: Slow audit queries  
**Optimization**:
```ruby
# Add missing indexes
Event.connection.execute("
  CREATE INDEX CONCURRENTLY events_custom_idx 
  ON events (auditable_type, auditable_id, created_at DESC)
")

# Optimize queries with proper includes
events = Event.where(auditable: application)
             .includes(:user)
             .order(created_at: :desc)
             .limit(50)  # Paginate large results
```

---

## 14 · Best Practices

### 14.1 · Event Creation Guidelines

- **Use AuditEventService.log()** for all audit events
- **Include meaningful metadata** that provides context for future analysis
- **Set Current attributes** in controllers for proper context capture
- **Avoid model callbacks** for audit events when possible - prefer service-layer auditing
- **Use descriptive action names** that clearly indicate what happened

### 14.2 · Performance Best Practices

- **Paginate large audit trails** to avoid memory issues
- **Use includes()** to prevent N+1 queries when loading related data
- **Index frequently queried metadata fields** using PostgreSQL partial indexes
- **Archive old events** to maintain query performance
- **Batch insert** when creating multiple events

### 14.3 · Security Considerations

- **Sanitize metadata** to prevent injection attacks
- **Limit metadata size** to prevent abuse
- **Audit the audit system** - log access to audit trails
- **Protect sensitive data** - avoid storing PII in metadata
- **Implement retention policies** for compliance requirements

---

**Tools**: Currently, audit events are viewed through the admin application detail pages via the `Applications::AuditLogBuilder` service. Dedicated admin audit interfaces, search/export endpoints, and integrity check tasks are planned but not currently implemented.
