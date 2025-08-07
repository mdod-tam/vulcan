# Service Architecture

Short, actionable reference for how our service objects work and how to build new ones.

---

## 1 · Philosophy

| Principle | In practice |
|-----------|-------------|
| **Encapsulate business logic** | One service ↔ one use-case. Keep controllers/models thin. |
| **Consistent patterns** | All services inherit helpers from `BaseService`. |
| **Transactional safety** | Wrap side-effect chains in DB transactions. |
| **Clear result surface** | Return `true/false`, expose `errors`. Complex services may return a result hash. |

---

## 2 · BaseService

```ruby
class BaseService
  attr_reader :errors

  # Default result object returned by services
  Result = Struct.new(:success, :message, :data, keyword_init: true) do
    def success?
      success == true
    end

    def failure?
      !success?
    end
  end

  def initialize(*_args)
    @errors = []
  end

  # Returns a success result with optional message and data
  def success(message = nil, data = nil)
    Result.new(success: true, message: message, data: data)
  end

  # Returns a failure result with optional message and data
  def failure(message = nil, data = nil)
    Result.new(success: false, message: message, data: data)
  end

  protected

  # Add an error message to the errors array
  def add_error?(message)
    @errors << message
    false
  end

  # Log an error with optional context and add to errors array
  def log_error(exception, context = nil)
    error_message = if context.is_a?(String)
                      "#{self.class.name}: #{context} - #{exception.message}"
                    elsif context.is_a?(Hash)
                      "#{self.class.name}: #{exception.message} | Context: #{context.inspect}"
                    else
                      "#{self.class.name}: #{exception.message}"
                    end

    Rails.logger.error error_message
    Rails.logger.error exception.backtrace.join("\n") if exception.backtrace

    add_error?(exception.message)
  end
end
```

---

## 3 · Core Services (examples)

### 3.1 · Applications::EventDeduplicationService

```ruby
deduped = Applications::EventDeduplicationService
           .new.deduplicate(events)
```

* **Single source of truth** for event deduping.  
* 1-minute buckets, priority: StatusChange > Event > Notification.  
* Fingerprints events via `event_fingerprint(event)`.

<details>
<summary>Fingerprint snippet</summary>

```ruby
def event_fingerprint(event)
  action  = generic_action(event)
  details = case event
            when ApplicationStatusChange
              medical_certification_event?(event) ? nil :
                "#{event.from_status}-#{event.to_status}"
            when ->(e) { e.action&.include?('proof_submitted') }
              "#{event.metadata['proof_type']}-#{event.metadata['submission_method']}"
            end
  [action, details].compact.join('_')
end
```
</details>

---

### 3.2 · Applications::MedicalCertificationService

```ruby
service = Applications::MedicalCertificationService
            .new(application: app, actor: current_user)
result = service.request_certification
# Returns BaseService::Result with success?, message, data
```

* Uses `update_columns` to avoid unrelated validations.  
* Timestamps = audit trail.  
* Background jobs for emails (`MedicalCertificationEmailJob`); graceful error capture.
* Returns structured result object instead of boolean.

---

### 3.3 · Applications::PaperApplicationService

(See **Paper Application Architecture** doc for full details.)

Key points:

| Concern | How handled |
|---------|-------------|
| Validation bypass | `Current.paper_context = true` |
| Self vs dependent | GuardianRelationship creation when needed |
| Proofs | Accept / reject, uploads, audits |
| Notifications | Triggered after success |

---

### 3.4 · Applications::EventService

```ruby
service = Applications::EventService
            .new(application: app, user: current_user)
service.log_dependent_application_update(
  dependent: dep, relationship_type: 'Parent'
)
```

Centralises event + metadata logging.

---

### 3.5 · ProofAttachmentService

```ruby
result = ProofAttachmentService.attach_proof(
  application:        app,
  proof_type:         :income,  # Symbol, not string
  blob_or_file:       uploaded_file,
  status:             :approved,
  admin:              current_user,
  submission_method:  :paper,
  metadata:           { ip: request.remote_ip }
)
# Returns: { success: true/false, error: nil, duration_ms: 123, blob_size: 456 }
```

* **Single source of truth** for all proof attachments (web, paper, email, fax).  
* Supports files **or** signed blob IDs.  
* Auto-creates audits; honours `Current.paper_context`; returns hash result.
* Includes metrics, timing, and error handling.
* Also provides `reject_proof_without_attachment` for paper rejections.

---

## 4 · Service Patterns & Helpers

### 4.1 · CurrentAttributes

```ruby
Current.paper_context                    # bypass proof checks
Current.skip_proof_validation           # broader bypass
Current.force_notifications             # useful in tests
Current.resubmitting_proof              # proof resubmission context
Current.reviewing_single_proof          # targeted review operations
Current.proof_attachment_service_context # prevent duplicate events
Current.user                            # current user for request context
Current.request_id                      # tracking and debugging
```

* Rails-native cleanup between requests.  
* Test isolation with `Current.reset` in teardown.
* Boolean helper methods: `paper_context?`, `resubmitting_proof?`, etc.

### 4.2 · Standard Error Handling

```ruby
def perform_operation
  ActiveRecord::Base.transaction do
    return add_error('Validation failed') unless valid?

    perform_core_logic
    true
  end
rescue => e
  log_error(e, 'perform_operation')
  add_error(e.message)
end
```

### 4.3 · Result Object Template

**BaseService::Result (structured):**
```ruby
Result.new(success: true, message: 'Success message', data: { user: user })
# Access via: result.success?, result.failure?, result.message, result.data
```

**Hash Result (for complex operations):**
```ruby
{ success: false, error: exception, duration_ms: 123, blob_size: 456 }
```

Use BaseService::Result for most services; hash results for complex operations like ProofAttachmentService.

---

## 5 · Guardian / Dependent Logic (in services)

```ruby
# Modern pattern using GuardianDependentManagementService
service = Applications::GuardianDependentManagementService.new(params)
result = service.process_guardian_scenario(
  guardian_id, new_guardian_attrs, applicant_data, relationship_type
)

if result.success?
  guardian = result.data[:guardian]
  dependent = result.data[:dependent]
else
  # Handle failure
end

# Direct relationship creation (legacy pattern still used)
GuardianRelationship.create!(
  guardian_user: guardian,
  dependent_user: dependent,
  relationship_type: relationship_type
)
```

---

## 6 · Testing Services

### 6.1 · Unit Test Skeleton

```ruby
class FooServiceTest < ActiveSupport::TestCase
  setup { @admin = create(:admin) }

  test 'success' do
    service = FooService.new(admin: @admin)
    assert service.perform
    assert_empty service.errors
  end

  test 'handles failure' do
    Foo.stubs(:create!).raises(StandardError, 'boom')
    service = FooService.new(admin: @admin)
    assert_not service.perform
    assert_includes service.errors, 'boom'
  end
end
```

### 6.2 · Integration Example

```ruby
assert_difference ['Application.count', 'GuardianRelationship.count'] do
  assert Applications::PaperApplicationService
           .new(params: dep_params, admin: @admin).create
end
```

---

## 7 · When to Extract a Service

* Logic spans **multiple models**.  
* Needs **transaction** wrapping.  
* Complex **error handling**.  
* **Background job** orchestration.  
* The controller/model would otherwise grow unwieldy.

---

## 8 · Additional Core Services

### 8.1 · NotificationService

```ruby
NotificationService.create_and_deliver!(
  type: 'proof_rejected',
  recipient: user,
  actor: admin,
  notifiable: review,
  metadata: { template_variables: ... },
  channel: :email
)
```

* **Centralized notification creation** with builder pattern.
* Supports fluent interface and direct call style.
* Handles delivery, tracking, and error recovery.

### 8.2 · AuditEventService

```ruby
AuditEventService.log(
  action: 'proof_approved',
  actor: admin,
  auditable: application,
  metadata: { proof_type: 'income' }
)
```

* **Single source** for audit event creation.
* Automatic deduplication within 5-second window.
* Structured metadata handling.

### 8.3 · Training & Evaluation Services

```ruby
# TrainingSessions::UpdateStatusService
# TrainingSessions::CompleteService
# Evaluations::SchedulingService
```

* Status management with proper state transitions.
* Notification orchestration.
* Audit trail maintenance.

## 9 · Future Service Candidates

| Area | Why |
|------|-----|
| Voucher management | Multi-step issuance, expiry, audit trail |
| Advanced reporting | Large data aggregation, formatting |
| Document processing | OCR, validation, classification |
| Integration services | External API coordination |

---

## 10 · Service Testing Patterns

### 10.1 · Unit Test Example

```ruby
class ProofAttachmentServiceTest < ActiveSupport::TestCase
  test 'successful attachment' do
    application = create(:application)
    file = fixture_file_upload('test.pdf', 'application/pdf')
    
    result = ProofAttachmentService.attach_proof(
      application: application,
      proof_type: :income,
      blob_or_file: file,
      submission_method: :web
    )
    
    assert result[:success]
    assert application.reload.income_proof.attached?
  end
end
```

### 10.2 · Service with BaseService::Result

```ruby
test 'medical certification service' do
  service = Applications::MedicalCertificationService.new(
    application: @application,
    actor: @admin
  )
  
  result = service.request_certification
  assert result.success?
  assert_equal 'Medical certification requested successfully.', result.message
end
```

## 11 · Dos & Don'ts

| Do | Don't |
|----|-------|
| Keep services PORO-ish | Render views |
| Return structured results (BaseService::Result or hash) | Return raw booleans for complex operations |
| Use Current attributes for context | Use Thread.current or global variables |
| Log & collect errors with context | Log without meaningful context |
| Maintain audits via AuditEventService | Create audit records directly |
| Use transactions for multi-step operations | Skip transactions when data consistency matters |
| Test with real data, not stubs for integration | Stub core service methods in integration tests |