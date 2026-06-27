# Proof Review Process Guide

A comprehensive guide to the complete proof review lifecycle in MAT Vulcan - from submission through approval/rejection, resubmission, and integration with the disability certification workflow.

This guide includes canonical documentation for the **ProofAttachmentService**, the central service responsible for all proof attachment operations in the application.

---

## 1 · ProofAttachmentService - Canonical Documentation

### 1.1 · Overview

The **ProofAttachmentService** is the single source of truth for all proof attachment operations in MAT Vulcan. It provides a unified interface for attaching proofs across both paper and online submission workflows, ensuring consistency in how attachments are processed, validated, and tracked.

### 1.2 · Key Responsibilities

- **Unified Interface**: Provides consistent API for both constituent portal and paper application workflows
- **File Handling**: Manages blob/file conversion for different input types (ActionDispatch::Http::UploadedFile, ActiveStorage::Blob, String paths)
- **Transaction Safety**: Ensures atomic operations with proper rollback on failures
- **Audit Trails**: Creates comprehensive audit records for all attachment operations
- **Context Management**: Handles `Current` attributes to coordinate with model callbacks
- **Error Handling**: Provides detailed error reporting and recovery mechanisms
- **Scope**: Handles income, residency, and ID proofs. Disability certification uses secure certification upload links, DocuSeal, fax/mail, or admin upload flows.

### 1.3 · Public API

#### Primary Method: `attach_proof`

```ruby
ProofAttachmentService.attach_proof({
  application: application,           # [Application] (required) Target application
  proof_type: :income,               # [Symbol] (required) :income, :residency, or :id
  blob_or_file: uploaded_file,       # [Mixed] (required) File to attach
  submission_method: :web,           # [Symbol] (required) :paper, :web, :secure_form, etc.
  status: :not_reviewed,             # [Symbol] (optional) Default: :not_reviewed
  admin: current_user,               # [User] (optional) Admin user if admin action
  metadata: { ip_address: '...' },   # [Hash] (optional) Additional metadata
  skip_audit_events: false           # [Boolean] (optional) Skip audit event creation
})
```

**Returns**: `Hash` with `:success`, `:error`, `:duration_ms`, and `:blob_size` keys

#### Secondary Method: `reject_proof_without_attachment`

```ruby
ProofAttachmentService.reject_proof_without_attachment(
  application: application,          # [Application] (required)
  proof_type: :income,              # [Symbol] (required)
  admin: admin_user,                # [User] (required) Admin performing rejection
  submission_method: :paper,        # [Symbol] (required)
  reason: 'unclear',                # [String] (optional) Rejection reason
  notes: 'Document illegible',      # [String] (optional) Additional notes
  metadata: {}                      # [Hash] (optional) Additional metadata
)
```

**Returns**: Same hash structure as `attach_proof`

### 1.4 · Context Management

The service uses `Current` attributes to coordinate with model callbacks and prevent duplicate events:

```ruby
# Service sets context during execution
Current.proof_attachment_service_context = true

# Paper application context is set automatically for :paper submission_method
Current.paper_context = true  # (for paper submissions only)

# These contexts prevent ProofManageable callbacks from creating duplicate events
```

### 1.5 · Supported File Types

Validation differs by submission channel:

- **Web/Paper (ProofManageable)**: `application/pdf`, `image/jpeg`, `image/png`, `image/tiff`, `image/bmp` with a 5MB max
- **Secure temporary forms (ProofAttachmentValidator)**: `application/pdf`, `image/jpeg`, `image/png` with a 1KB min and 10MB max, plus filename/content checks

### 1.6 · Error Handling

The service provides comprehensive error handling with detailed diagnostics:

```ruby
result = ProofAttachmentService.attach_proof(params)

unless result[:success]
  error = result[:error]
  Rails.logger.error "Attachment failed: #{error.message}"
  # Handle failure appropriately
end
```

**Audit events**: `ProofAttachmentService` logs `#{proof_type}_proof_attached` for attachment submissions and `#{proof_type}_proof_rejected` for explicit rejection paths. Secure proof resubmission submission is logged by `Applications::SubmitProofResubmission` as `proof_submitted_via_secure_form`.

**Common Error Scenarios**:
- Invalid file types or sizes
- ActiveStorage signed ID errors (auto-recovery implemented)
- Database transaction failures
- Missing required parameters

### 1.7 · Integration Points

#### With Controllers
```ruby
# Constituent Portal
def resubmit
  result = ProofAttachmentService.attach_proof({
    application: @application,
    proof_type: params[:proof_type],
    blob_or_file: params[:"#{params[:proof_type]}_proof_upload"],
    submission_method: :web,
    admin: current_user
  })
  # Handle result...
end
```

#### With Paper Application Service
```ruby
# Paper Application Processing
def process_accept_proof(type)
  result = ProofAttachmentService.attach_proof({
    application: @application,
    proof_type: type,
    blob_or_file: extract_proof_file(type),
    submission_method: :paper,
    admin: @admin_user
  })
  # Handle result...
end
```

#### With Secure Proof Resubmission
```ruby
# Issued after a proof is rejected or an admin requests more proof.
Applications::RequestProofResubmission.new(
  application: application,
  actor: admin,
  proof_type: :income
).call

# Public token submission path delegates to this service.
Applications::SubmitProofResubmission.new(
  application: application,
  secure_request_form: secure_request_form,
  file: params[:file]
).call
```

`Applications::SubmitProofResubmission` validates the uploaded file with `ProofAttachmentValidator`, attaches it through:

```ruby
ProofAttachmentService.attach_proof({
  application: application,
  proof_type: :income,
  blob_or_file: file,
  submission_method: :secure_form,
  status: :not_reviewed,
  metadata: {
    secure_request_form_id: secure_request_form.id,
    request_batch_id: secure_request_form.request_batch_id
  }
})
```

### 1.8 · Event Creation

The service creates standardized audit events:

- **Attachment Events**: `#{proof_type}_proof_attached` (for :web and :paper)
- **Secure Form Events**: `proof_resubmission_requested`, `proof_submitted_via_secure_form`, `proof_resubmission_request_revoked`, `proof_resubmission_request_expired`
- **Rejection Events**: `#{proof_type}_proof_rejected`
- **Failure Events**: `#{proof_type}_proof_attachment_failed`

All events include comprehensive metadata:
```ruby
{
  proof_type: 'income',
  submission_method: 'web',
  status: 'not_reviewed',
  has_attachment: true,
  blob_id: 123,
  blob_size: 1024000,
  filename: 'proof.pdf',
  success: true
}
```

### 1.9 · Testing Considerations

**Important**: Do NOT stub `ProofAttachmentService.attach_proof` in integration tests. This method performs actual file attachment logic, and stubbing it will cause tests to report success without creating actual attachments, leading to false positives.

```ruby
# ✅ Correct - Let service run normally
result = ProofAttachmentService.attach_proof(params)
expect(result[:success]).to be true
expect(application.income_proof.attached?).to be true

# ❌ Incorrect - Stubbing breaks integration testing
allow(ProofAttachmentService).to receive(:attach_proof).and_return({success: true})
```

### 1.10 · Performance Characteristics

- **Transaction Scope**: All operations are wrapped in database transactions
- **Blob Creation**: Handles both pre-existing blobs and new file uploads
- **Memory Efficiency**: Streams large files without loading entirely into memory
- **Failure Recovery**: Automatic retry for ActiveStorage signature errors

---

## 2 · Process Overview

| Stage | Actor | Key Components | Status Transitions |
|-------|-------|---------------|-------------------|
| **1. Submission** | Constituent/Admin | `ProofAttachmentService`, `ProofManageable` | `draft` → `in_progress` |
| **2. Review** | Admin | `ProofReviewer`, `ProofReviewService` | `in_progress` → `approved`/`rejected` |
| **3. Resubmission** | Constituent | `SecureRequestForm`, `Applications::SubmitProofResubmission` | `proof_status` → `not_reviewed` |
| **4. Reconciliation** | System | `Applications::ProofReviewer`, `Application#reconcile_workflow_state!` | Check for completion → `approved` when eligible |

---

## 3 · Core Components

### 3.1 · Service Layer Architecture

| Service | Purpose | Usage Pattern |
|---------|---------|---------------|
| **`ProofAttachmentService`** | Handle uploads, validation, audit trails | Used by both portal + paper workflows |
| **`ProofReviewService`** | Orchestrate review process, parameter validation | Called by admin controllers |
| **`Applications::ProofReviewer`** | Core review logic, `update!` status writes, workflow reconciliation | Called by `ProofReviewService` |
| **`ProofAttachmentValidator`** | File validation (size, type, content) | Called by secure proof/certification upload services |

### 3.2 · Model Concerns

| Concern | Responsibility | Key Methods |
|---------|----------------|-------------|
| **`ProofManageable`** | Proof lifecycle, attachment management | `all_proofs_approved?`, `set_needs_review_timestamp`, `purge_rejected_proof` |
| **`ProofConsistencyValidation`** | Status consistency validation | `validate_proof_status_consistent_with_application_status` |
| **`ApplicationStatusManagement`** | Status transitions, automated actions | Coordinates approval state and disability certification requests |

---

## 4 · Submission Workflows

### 4.1 · Constituent Portal Submission

```ruby
# app/controllers/constituent_portal/proofs/proofs_controller.rb
def resubmit # This action handles resubmission of proofs
  # ... (rate limit and authorization checks)

  ActiveRecord::Base.transaction do
    result = ProofAttachmentService.attach_proof({
      application: @application,
      proof_type: params[:proof_type],
      blob_or_file: params[:"#{params[:proof_type]}_proof_upload"], # File param
      status: :not_reviewed, # Default status for constituent uploads
      admin: current_user, # Constituent is the actor
      submission_method: :web,
      metadata: { ip_address: request.remote_ip }
    })

    raise "Failed to attach proof: #{result[:error]&.message}" unless result[:success]

    # Audit event for proof submission is handled by the `track_submission` method in this controller.
    # Application status (e.g., needs_review_since) is updated via ProofManageable concern.
    # Note: `ProofAttachmentService` sets `Current.proof_attachment_service_context = true`
    # during its execution. This causes the `ProofManageable` concern to skip its own audit event creation,
    # which prevents duplicate events.
  end

  redirect_to constituent_portal_application_path(@application), notice: 'Proof submitted successfully'
end
```

### 4.2 · Paper Application Submission

```ruby
# app/services/applications/paper_application_service.rb
def process_proof_uploads
  Current.paper_context = true # Set paper context for the entire flow
  begin
    # Process income proof
    income_result = process_proof(:income)
    return false unless income_result

    # Process residency proof
    residency_result = process_proof(:residency)
    return false unless residency_result

    true
  ensure
    Current.paper_context = nil # Always clear the Current attribute
  end
end

private

def process_proof(type)
  action = extract_proof_action(type) # 'accept' or 'reject'

  case action
  when 'accept'
    # Calls ProofAttachmentService.attach_proof internally
    process_accept_proof(type)
  when 'reject'
    # Calls ProofAttachmentService.reject_proof_without_attachment internally
    process_reject_proof(type)
  else
    true # No action specified, proceed
  end
end

# Note on Audit Events in PaperApplicationService:
# - When a proof is accepted with a file, `ProofAttachmentService` creates a `#{type}_proof_attached` audit event.
# - When a proof is rejected (no file required), `ProofAttachmentService` creates a `#{type}_proof_rejected` audit event.
# - Selecting approve without a file returns a validation error surfaced via flash.
```

### 4.3 · Secure Proof Resubmission

Rejected or missing proofs are resubmitted through tokenized secure forms. `Applications::RequestProofResubmission` creates `SecureRequestForm` records and notifications; public upload controllers call `Applications::SubmitProofResubmission`.

```ruby
request_result = Applications::RequestProofResubmission.new(
  application: application,
  actor: admin,
  proof_type: :income
).call

submit_result = Applications::SubmitProofResubmission.new(
  application: application,
  secure_request_form: request_result.data.fetch(:secure_request_forms).first,
  file: uploaded_file
).call
```

---

## 5 · Review Process

### 5.1 · Admin Review Interface

| Controller | Route | Purpose |
|------------|-------|---------|
| **`Admin::ProofReviewsController`** | `/admin/applications/:id/proof_reviews` | Main review interface |
| **`Admin::ScannedProofsController`** | `/admin/applications/:id/scanned_proofs` | Upload scanned documents |
| **`Admin::ApplicationsController`** | `/admin/applications` | Application management |

### 5.2 · Review Workflow

```ruby
# app/controllers/admin/applications_controller.rb
# This action handles updating proof status (approving/rejecting)
def update_proof_status
  admin_user = validate_and_prepare_admin_user # Ensures current_user is an admin

  # Instantiate and call the ProofReviewService
  service = ProofReviewService.new(@application, admin_user, params)
  result = service.call # This calls Applications::ProofReviewer internally

  # Handle the result from the service
  if result.success?
    # ProofReviewService validates params and delegates to Applications::ProofReviewer.
    # Applications::ProofReviewer handles ProofReview creation, status updates, purging, and auto-approval checks. ProofReview callbacks handle audit events + notifications.
    handle_successful_review # This method handles redirect/turbo_stream response
  else
    # Handle failure (e.g., validation errors from service)
    respond_to do |format|
      format.html { render :show, status: :unprocessable_entity, alert: result.message }
      format.turbo_stream do
        flash.now[:error] = result.message
        render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash')
      end
    end
  end
end
```

### 5.3 · Core Review Logic

`ProofReviewService` is the controller-facing orchestrator. It validates the requested proof type and status, calls `Applications::ProofReviewer`, and returns a `BaseService::Result`.

`Applications::ProofReviewer` owns the transaction:

1. Resolve the rejection reason text from `RejectionReason` when a code is provided.
2. Create or update the `ProofReview` record.
3. Update the application proof status with `update!`, so validations and callbacks stay in play.
4. Purge the rejected proof attachment when the review rejects the proof.
5. Reconcile workflow state after approvals with `Application#reconcile_workflow_state!`.

Approvals do not manually set the application to approved. The reconciliation path checks the full application state and moves the application forward only when required proofs and disability certification are complete.

For rejected reviews, `ProofReviewService` includes `resubmission_delivered` in the result data. If review succeeds but secure proof upload request delivery fails, admin controllers still complete the review and show an alert so staff can resend or inspect the secure upload link.

---

## 6 · Status Management

### 6.1 · Proof-Specific Status Fields

| Field | Purpose | Values |
|-------|---------|--------|
| `income_proof_status` | Track income document review | `not_reviewed`, `approved`, `rejected` |
| `residency_proof_status` | Track residency document review | `not_reviewed`, `approved`, `rejected` |
| `medical_certification_status` | Track disability certification process | `not_requested`, `requested`, `received`, `approved`, `rejected` |

### 6.2 · Application Status Integration

```ruby
# app/models/concerns/application_status_management.rb
after_save :handle_status_change, if: :saved_change_to_status?
after_save :auto_approve_if_eligible, if: :should_auto_approve?

private

def handle_status_change
  return unless status_previously_changed?(to: 'awaiting_dcf')

  handle_awaiting_dcf_transition
end

def handle_awaiting_dcf_transition
  return unless all_proofs_approved?
  return if medical_certification_status_requested?

  with_lock do
    update!(medical_certification_status: :requested)
    MedicalProviderMailer.request_certification(self).deliver_later
  end
end

def all_requirements_met?
  income_proof_status_approved? &&
    residency_proof_status_approved? &&
    medical_certification_status_approved?
end

def should_auto_approve?
  return false if status_approved? || status_rejected? || status_archived?

  all_requirements_met?
end

def auto_approve_if_eligible
  previous_status = status
  @pending_status_change_user = Current.user
  @pending_status_change_notes = 'Auto-approved based on all requirements being met'
  update!(status: 'approved')
  create_auto_approval_audit_event(previous_status)
end

# Creates an audit event for the auto-approval
def create_auto_approval_audit_event(previous_status)
  return unless defined?(Event) && Event.respond_to?(:create)

  begin
    # Use Current.user if available, otherwise fall back to a system user for automated processes
    acting_user = Current.user || User.find_by(email: 'system@example.com') || User.first
    Event.create!(
      user: acting_user,
      action: 'application_auto_approved',
      metadata: {
        application_id: id,
        old_status: previous_status,
        new_status: status,
        timestamp: Time.current.iso8601,
        auto_approval: true,
        triggered_by_user_id: acting_user&.id
      }
    )
  rescue StandardError => e
    # Log error but don't prevent the auto-approval
    Rails.logger.error("Failed to create event for auto-approval: #{e.message}")
  end
end
```

**Post-review hook**: After a proof is approved, workflow reconciliation checks whether the application can move forward. When reviewable proofs are complete, the application can move into disability certification. When required proofs and disability certification are all approved, reconciliation can approve the application.

Disability certification submissions are handled through secure certification upload links, DocuSeal, fax/mail, or admin upload. Secure uploads call `Applications::SubmitCertificationUpload`, attach the certification file, create `cert_submitted_via_secure_form`, and record `submission_method: 'secure_form'` metadata.

---

## 7 · Resubmission Process

### 7.1 · Portal Resubmission

```ruby
# app/controllers/constituent_portal/dashboards_controller.rb
def can_resubmit_proof?(application, proof_type, max_submissions)
  # Only allow resubmission for rejected proofs
  status_method = "#{proof_type}_proof_status_rejected?"
  return false unless application.send(status_method)

  # Check if under the maximum number of allowed resubmissions
  submission_count = count_proof_submissions(application, proof_type)
  submission_count < max_submissions
end
```

### 7.2 · Secure Form Resubmission

```ruby
# app/services/applications/request_proof_resubmission.rb
Applications::RequestProofResubmission.new(
  application: application,
  actor: admin,
  proof_type: :income
).call

# app/services/applications/submit_proof_resubmission.rb
Applications::SubmitProofResubmission.new(
  application: application,
  secure_request_form: secure_request_form,
  file: uploaded_file
).call
```

When a rejected proof review requests resubmission, `Applications::RequestProofResubmission` creates tracking records and attempts delivery through the selected channel. If delivery fails, the proof review still succeeds; the failed delivery is surfaced to admins as an alert and staff can resend from the secure upload link workflow.

---

## 8 · Audit Trail & Events

### 8.1 · Automatic Audit Creation

```ruby
# app/services/proof_attachment_service.rb
def log_audit_event(context, event_metadata)
  AuditEventService.log(
    action: "#{context.proof_type}_proof_attached",
    auditable: context.application,
    actor: context.admin || context.application.user,
    metadata: event_metadata
  )
end
```

**Other audit sources**:

- `Applications::RequestProofResubmission` creates `proof_resubmission_requested` notifications and audit events.
- `Applications::SubmitProofResubmission` logs `proof_submitted_via_secure_form`.
- `SecureTokenizable` and `SecureFormExpirationRecorder` log secure form revocation and expiration events.
- `ProofAttachmentService` logs `*_proof_attachment_failed` on errors.

### 8.2 · Review Audit Events

`ProofReview` callbacks own the post-review side effects:

- Approved proof reviews log `proof_approved` and create a record-only notification with `deliver: false`.
- Rejected proof reviews log `proof_rejected` and call `Applications::RequestProofResubmission`.
- Repeat rejections run extra side effects after the review transaction, so the application status, review record, and secure request state remain consistent.

`ProofReviewService` does not create audit events directly. It delegates to `Applications::ProofReviewer` and returns delivery metadata for the admin response.

---

## 9 · Disability Certification Integration

### 9.1 · Automatic Disability Certification Requests

```ruby
# app/models/concerns/application_status_management.rb
after_save :handle_status_change, if: :saved_change_to_status?

private

# Handles transitions to specific statuses that trigger automated actions.
# Currently triggers the auto-request for disability certification when transitioning to 'awaiting_dcf'.
def handle_status_change
  return unless status_previously_changed?(to: 'awaiting_dcf')

  handle_awaiting_dcf_transition
end

# Triggered when the application status transitions to 'awaiting_dcf'.
# Checks if income and residency proofs are approved.
# If so, updates the medical_certification_status code field to 'requested' and sends an email to the certifying professional.
def handle_awaiting_dcf_transition
  # Ensure income and residency proofs are approved
  return unless all_proofs_approved?
  # Avoid re-requesting if already requested
  return if medical_certification_status_requested?

  # Update certification status and send email
  with_lock do
    update!(medical_certification_status: :requested)
    MedicalProviderMailer.request_certification(self).deliver_later
  end
end
```

### 9.2 · Disability Certification Status

```ruby
# Disability certification has its own status field and workflow integration.
# Code identifiers still use medical_certification_* names.

# Check if disability certification is considered "complete" for application processing.
# For example: application.medical_certification_status_received? || application.medical_certification_status_approved?

# This method is used internally by ApplicationStatusManagement.
# It checks whether required proofs and disability certification are approved.
def all_requirements_met?
  income_proof_status_approved? &&
    residency_proof_status_approved? &&
    medical_certification_status_approved?
end

# Check whether disability certification has not yet been requested.
# For example: application.medical_certification_status_not_requested?
```

---

## 10 · Background Jobs & Monitoring

### 10.1 · Automated Monitoring

| Job | Purpose | Schedule |
|-----|---------|----------|
| **`ProofReviewReminderJob`** | Notify admins of stale reviews | Daily |
| **`ProofConsistencyCheckJob`** | Validate data integrity | Weekly |
| **`ProofAttachmentMetricsJob`** | Monitor failure rates | Hourly |
| **`CleanupOldProofsJob`** | Archive old attachments | Daily |

### 10.2 · Failure Rate Monitoring

```ruby
# app/jobs/proof_attachment_metrics_job.rb
SUCCESS_RATE_THRESHOLD = 95.0 # Alert if success rate falls below 95%
MINIMUM_FAILURES_THRESHOLD = 5 # Only alert if we have at least 5 failures

def perform
  Rails.logger.info 'Analyzing Proof Submission Failure Rates'

  # Define the relevant actions for attachment success and failure
  attachment_actions = %w[
    income_proof_attached residency_proof_attached
    income_proof_attachment_failed residency_proof_attachment_failed
  ]

  # Get recent proof attachment events (last 24 hours)
  recent_events = Event.where(action: attachment_actions)
                       .where('created_at > ?', 24.hours.ago)

  total_submissions = recent_events.count
  failed_submissions = recent_events.where("action LIKE '%_failed'").count
  successful_submissions = total_submissions - failed_submissions

  # Calculate success rate
  success_rate = if total_submissions.positive?
                   (successful_submissions.to_f / total_submissions * 100).round(1)
                 else
                   100.0
                 end

  Rails.logger.info "Proof Submission Analysis (Last 24 Hours): " \
                    "Total: #{total_submissions}, " \
                    "Successful: #{successful_submissions}, " \
                    "Failed: #{failed_submissions}, " \
                    "Success Rate: #{success_rate}%"

  # Alert administrators if failure rate is too high and minimum failures threshold is met
  if success_rate < SUCCESS_RATE_THRESHOLD && failed_submissions >= MINIMUM_FAILURES_THRESHOLD
    alert_administrators(success_rate, total_submissions, failed_submissions)
  end

  Rails.logger.info 'Proof submission failure rate analysis completed'
end

```

---

## 11 · Frontend Integration

### 11.1 · Stimulus Controllers

| Controller | Purpose | File Location |
|------------|---------|---------------|
| **`DocumentProofHandlerController`** | Admin proof accept/reject UI | `app/javascript/controllers/users/` |
| **`ProofStatusController`** | Show/hide sections based on status | `app/javascript/controllers/reviews/` |
| **`RejectionFormController`** | Dynamic rejection reason forms | `app/javascript/controllers/forms/` |

### 11.2 · Dynamic UI Behavior

```javascript
// app/javascript/controllers/reviews/proof_status_controller.js
toggle(event) {
  // Check for both "approved" and "accepted" values because proof review and
  // disability certification review use different status labels.
  const isApproved = event.target.value === "approved" || event.target.value === "accepted"
  
  // Use setVisible utility for consistent visibility management
  this.withTarget('uploadSection', (target) => setVisible(target, isApproved));
  this.withTarget('rejectionSection', (target) => setVisible(target, !isApproved));
}
```

---

## 12 · Testing Patterns

### 12.1 · Service Testing

```ruby
# Focus on transaction safety and error handling
test 'creates a ProofReview record and updates application status on success' do
  assert_difference('ProofReview.count', 1) do
    service.review(proof_type: 'income', status: 'approved')
  end
  assert @application.reload.income_proof_status_approved?
end

test 'does not roll back ProofReview on notification failure' do
  Applications::RequestProofResubmission.any_instance.stub(:call, -> {
    BaseService::Result.failure("delivery failed", data: { delivery_failed: true })
  }) do
    assert_difference('ProofReview.count', 1) do
      service.review(proof_type: 'income', status: 'rejected')
    end
  end
  assert @application.reload.income_proof_status_rejected?
  assert AdminAlert.where(alert_type: 'secure_upload_request_delivery_failed').exists?
end

test 'raises on critical database errors during review' do
  ProofReview.any_instance.stub(:save!, -> { raise ActiveRecord::RecordInvalid.new(ProofReview.new) }) do
    assert_raises(ActiveRecord::RecordInvalid) do
      service.review(proof_type: 'income', status: 'approved')
    end
  end
  assert @application.reload.income_proof_status_not_reviewed?
end
```

### 12.2 · Integration Testing

```ruby
# Test complete workflows end-to-end
test 'handles approval process from submission to admin review' do
  application = create(:application, :in_progress, user: constituent)
  application.update!(medical_certification_status: :approved)

  post resubmit_proof_document_constituent_portal_application_path(application, proof_type: 'income'),
       params: { income_proof_upload: fixture_file_upload('test_proof.pdf', 'application/pdf') }
  post resubmit_proof_document_constituent_portal_application_path(application, proof_type: 'residency'),
       params: { residency_proof_upload: fixture_file_upload('test_proof.pdf', 'application/pdf') }

  assert_difference('ProofReview.count', 2) do
    patch update_proof_status_admin_application_path(application),
          params: { proof_type: 'income', status: 'approved' }
    patch update_proof_status_admin_application_path(application),
          params: { proof_type: 'residency', status: 'approved' }
  end

  assert application.reload.status_approved?
  assert ProofReview.where(application: application, status: 'approved').count >= 2
end
```

---

## 13 · Common Troubleshooting

### 13.1 · Status Inconsistencies

**Problem**: Application status doesn't match proof statuses  
**Solution**: Run `ProofConsistencyCheckJob` or use Rails console:

```ruby
# Fix inconsistent application (if proofs are approved but application status is not)
# If an application's income, residency, ID, and disability certification statuses
# are all approved but the application status itself is not approved, trigger the
# same reconciliation path the review service uses.

app = Application.find(123)
app.reconcile_workflow_state!

# Alternatively, an administrator can manually approve the application via the UI or console:
# app.approve!(user: User.find_by(email: 'admin@example.com'))
```

### 13.2 · Missing Audit Trails

**Problem**: Proof submissions not creating audit events  
**Check**: `ProofAttachmentService` logging and `skip_audit_events` usage; for secure resubmissions, check `Applications::SubmitProofResubmission#log_submission`

```ruby
# app/services/proof_attachment_service.rb
def log_audit_event(context, event_metadata)
  return if context.skip_audit_events

  AuditEventService.log(
    action: "#{context.proof_type}_proof_attached",
    actor: context.admin || context.application.user,
    auditable: context.application,
    metadata: event_metadata
  )
end
```

### 13.3 · Secure Upload Failures

**Problem**: Secure proof uploads are rejected or not attached
**Debug**: Check `SecureRequestForm.active_for_public_use?`, controller form errors, `ProofAttachmentValidator`, and `Applications::SubmitProofResubmission`

---

## 14 · Future Enhancements

### 14.1 · Planned Improvements

- **DocuSeal monitoring**: Enhance retries/telemetry around document signing

### 14.2 · Technical Debt

- **Proof Type Enumeration**: Centralize proof type definitions
- **Status Field Consolidation**: Consider JSON column for complex statuses
- **Notification Template Standardization**: Move all messages to `NotificationComposer`

---

**Tools**: Admin dashboard (`/admin/applications`) · Secure form admin tables · Audit logs (`/admin/events`) · Background job monitoring (`/admin/jobs`)
