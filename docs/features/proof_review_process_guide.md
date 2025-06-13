# Proof Review Process Guide

A comprehensive guide to the complete proof review lifecycle in MAT Vulcan - from submission through approval/rejection, resubmission, and integration with the medical certification workflow.

---

## 1 · Process Overview

| Stage | Actor | Key Components | Status Transitions |
|-------|-------|---------------|-------------------|
| **1. Submission** | Constituent/Admin | `ProofAttachmentService`, `ProofManageable` | `draft` → `in_progress` |
| **2. Review** | Admin | `ProofReviewer`, `ProofReviewService` | `in_progress` → `approved`/`rejected` |
| **3. Resubmission** | Constituent | `ProofSubmissionMailbox`, Portal UI | `proof_status` → `not_reviewed` |
| **4. Auto-Approval** | System | `Applications::ProofReviewer` | Check for completion → `approved` |

---

## 2 · Core Components

### 2.1 · Service Layer Architecture

| Service | Purpose | Usage Pattern |
|---------|---------|---------------|
| **`ProofAttachmentService`** | Handle uploads, validation, audit trails | Used by both portal + paper workflows |
| **`ProofReviewService`** | Orchestrate review process, parameter validation | Called by admin controllers |
| **`Applications::ProofReviewer`** | Core review logic, status updates, auto-approval | Called by `ProofReviewService` |
| **`ProofAttachmentValidator`** | File validation (size, type, content) | Called during upload process |

### 2.2 · Model Concerns

| Concern | Responsibility | Key Methods |
|---------|----------------|-------------|
| **`ProofManageable`** | Proof lifecycle, attachment management | `all_proofs_approved?`, `create_proof_submission_audit` |
| **`ProofConsistencyValidation`** | Status consistency validation | `validate_proof_status_consistent_with_application_status` |
| **`ApplicationStatusManagement`** | Status transitions, automated actions | Triggers medical cert requests |

---

## 3 · Submission Workflows

### 3.1 · Constituent Portal Submission

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
    # Note: `ProofAttachmentService` is *not* called with `skip_audit_events: true` in this flow.
    # Instead, `ProofAttachmentService` sets `Current.proof_attachment_service_context = true`
    # during its execution, which causes the `ProofManageable` concern to skip its own audit event creation,
    # preventing duplicate events.
  end

  redirect_to constituent_portal_application_path(@application), notice: 'Proof submitted successfully'
end
```

### 3.2 · Paper Application Submission

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
# - If 'accept' with a file, `ProofAttachmentService` creates a `#{type}_proof_attached` audit event.
# - If 'accept' without a file (paper context), `PaperApplicationService` creates a `proof_submitted` audit event.
# - If 'reject', `ProofAttachmentService` creates a `#{type}_proof_rejected` audit event.
```

### 3.3 · Email Submission via Action Mailbox

```ruby
# app/mailboxes/proof_submission_mailbox.rb
def process
  # Create an audit record for the initial email receipt
  create_audit_record

  # Process each attachment in the email
  mail.attachments.each do |attachment|
    # Determine proof type based on email subject or content
    proof_type = determine_proof_type(mail.subject, mail.body.decoded)

    # Attach the file to the application's proof using the service
    attach_proof(attachment, proof_type)
  end

  # Notify admin of new proof submission (after all attachments are processed)
  notify_admin
end

private

def attach_proof(attachment, proof_type)
  # ... (blob creation)

  # Use the ProofAttachmentService to consistently handle attachments
  result = ProofAttachmentService.attach_proof({
                                                 application: application,
                                                 proof_type: proof_type,
                                                 blob_or_file: blob,
                                                 status: :not_reviewed,
                                                 admin: nil, # No admin for email submissions
                                                 submission_method: :email,
                                                 metadata: {
                                                   email_subject: mail.subject,
                                                   email_from: mail.from.first
                                                 }
  })

  raise "Failed to attach proof: #{result[:error]&.message}" unless result[:success]
  # ProofAttachmentService already handled the attachment and notifications.
  # Note on Audit Events in ProofSubmissionMailbox:
  # - `create_audit_record` creates `proof_submission_received`.
  # - `ProofAttachmentService` creates `#{proof_type}_proof_attached`.
  # - `notify_admin` creates `proof_submission_processed`.
end
```

---

## 4 · Review Process

### 4.1 · Admin Review Interface

| Controller | Route | Purpose |
|------------|-------|---------|
| **`Admin::ProofReviewsController`** | `/admin/applications/:id/proof_reviews` | Main review interface |
| **`Admin::ScannedProofsController`** | `/admin/applications/:id/scanned_proofs` | Upload scanned documents |
| **`Admin::ApplicationsController`** | `/admin/applications` | Application management |

### 4.2 · Review Workflow

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
    # ProofReviewService (and Applications::ProofReviewer) handles:
    # - Creating ProofReview record
    # - Updating application proof status fields
    # - Creating audit events
    # - Sending notifications
    # - Checking for auto-approval
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

### 4.3 · Core Review Logic

```ruby
# app/services/applications/proof_reviewer.rb
def review(proof_type:, status:, rejection_reason: nil, notes: nil)
  Rails.logger.info "Starting review with proof_type: #{proof_type.inspect}, status: #{status.inspect}"
  @proof_type_key = proof_type.to_s
  @status_key = status.to_s

  ApplicationRecord.transaction do
    # Create ProofReview record
    @proof_review = @application.proof_reviews.find_or_initialize_by(
      proof_type: @proof_type_key, status: @status_key
    )
    @proof_review.assign_attributes(admin: @admin, notes: notes, rejection_reason: rejection_reason)
    # If it's an existing record being updated, the `on: :create` `set_reviewed_at` callback
    # won't run. We need to explicitly update `reviewed_at` to reflect this new review action.
    # If it's a new record, the `on: :create` callback will set it.
    # `reviewed_at` is validated for presence, so it must be set before save!.
    if @proof_review.new_record?
      # `set_reviewed_at` callback will handle it via `before_validation :set_reviewed_at, on: :create`
    else
      @proof_review.reviewed_at = Time.current
    end
    @proof_review.save!

    # Update application proof status directly (bypasses callbacks)
    update_application_status

    # Explicitly purge attachment if proof was rejected
    purge_if_rejected
  end
  true # Indicate success
rescue StandardError => e
  Rails.logger.error "Proof review failed: #{e.message}"
  raise # Re-raise to ensure errors are visible
end

private

def update_application_status
  # ... (validation for attachment presence if approving)

  # Update the specific proof status column
  column_name = "#{@proof_type_key}_proof_status"
  status_enum_value = Application.send(column_name.pluralize.to_s).fetch(@status_key.to_sym)
  @application.update_column(column_name, status_enum_value)

  @application.reload # Reload to get latest state for auto-approval check

  # Check if auto-approval is now possible
  check_for_auto_approval
end

def check_for_auto_approval
  # Only check for auto-approval if application is not already approved
  return if @application.status_approved?

  # Auto-approval requires all three: income, residency, AND medical certification approved
  if @application.income_proof_status_approved? &&
     @application.residency_proof_status_approved? &&
     @application.medical_certification_status_approved?

            # Update application status to approved and create audit event
            @application.update_column(:status, Application.statuses[:approved])
            Event.create!(
              user: @admin, # Admin who triggered the final approval.
                            # Note: If auto-approved via `ApplicationStatusManagement` (e.g., by medical cert update),
                            # the 'user' for the `application_auto_approved` event will be `nil` (system).
                            # This is a known inconsistency in audit logging for auto-approval.
              action: 'application_auto_approved',
              auditable: @application,
              metadata: {
                application_id: @application.id,
                trigger: "proof_#{@proof_type_key}_approved"
              }
            )
            Rails.logger.info "Application #{@application.id} auto-approved after all requirements met"
          end
        end
```

---

## 5 · Status Management

### 5.1 · Proof-Specific Status Fields

| Field | Purpose | Values |
|-------|---------|--------|
| `income_proof_status` | Track income document review | `not_reviewed`, `approved`, `rejected` |
| `residency_proof_status` | Track residency document review | `not_reviewed`, `approved`, `rejected` |
| `medical_certification_status` | Track medical cert process | `not_requested`, `requested`, `received`, `approved`, `rejected` |

### 5.2 · Application Status Integration

```ruby
# app/models/concerns/application_status_management.rb
after_save :handle_status_change, if: :saved_change_to_status?
after_save :auto_approve_if_eligible, if: :requirements_met_for_approval?

private

# Handles transitions to specific statuses that trigger automated actions.
# Currently triggers the auto-request for medical certification when transitioning to 'awaiting_documents'.
def handle_status_change
  return unless status_previously_changed?(to: 'awaiting_documents')

  handle_awaiting_documents_transition
end

# Triggered when the application status transitions to 'awaiting_documents'.
# Checks if income and residency proofs are approved.
# If so, updates the medical certification status to 'requested' and sends an email to the medical provider.
def handle_awaiting_documents_transition
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

# Checks if the application itself is eligible for auto-approval.
# Eligibility requires income proof, residency proof, AND medical certification to be approved.
# This method is triggered after save if any of the relevant proof statuses change.
def requirements_met_for_approval?
  # Only run this when relevant fields have changed
  return false unless saved_change_to_income_proof_status? ||
                      saved_change_to_residency_proof_status? ||
                      saved_change_to_medical_certification_status?

  # Only auto-approve applications that aren't already approved
  return false if status_approved?

  # Check if all requirements are met (income, residency, and medical certification approved)
  all_requirements_met?
end

def all_requirements_met?
  income_proof_status_approved? &&
    residency_proof_status_approved? &&
    medical_certification_status_approved?
end

# Auto-approves the application when all requirements are met
# Uses proper Rails update mechanisms to ensure audit trails are created
def auto_approve_if_eligible
  previous_status = status
  update_application_status_to_approved
  create_auto_approval_audit_event(previous_status)
end

# Updates the application status using the model's status update method
# This ensures proper status change records are created
def update_application_status_to_approved
  update_status('approved', user: nil, notes: 'Auto-approved based on all requirements being met')
end

# Creates an audit event for the auto-approval
def create_auto_approval_audit_event(previous_status)
  return unless defined?(Event) && Event.respond_to?(:create)

  begin
    Event.create!(
      user: nil, # nil user indicates system action
      action: 'application_auto_approved',
      metadata: {
        application_id: id,
        old_status: previous_status,
        new_status: status,
        timestamp: Time.current.iso8601,
        auto_approval: true
      }
    )
  rescue StandardError => e
    # Log error but don't prevent the auto-approval
    Rails.logger.error("Failed to create event for auto-approval: #{e.message}")
  end
end
```

---

## 6 · Resubmission Process

### 6.1 · Portal Resubmission

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

### 6.2 · Email Resubmission

```ruby
# app/mailboxes/proof_submission_mailbox.rb
before_processing :check_max_rejections
before_processing :check_rate_limit

def check_max_rejections
  max_rejections = Policy.get('max_proof_rejections')
  return unless max_rejections.present? && application.total_rejections.present?
  return unless application.total_rejections >= max_rejections

  bounce_with_notification(
    :max_rejections_reached,
    'Maximum number of proof submission attempts reached'
  )
end
```

---

## 7 · Audit Trail & Events

### 7.1 · Automatic Audit Creation

```ruby
# app/models/concerns/proof_manageable.rb
def create_proof_submission_audit
  # Guard clause to prevent infinite recursion
  return if @creating_proof_audit
  return unless proof_attachments_changed?
  
  # Skip if ProofAttachmentService is handling the audit (paper context or service context)
  # This prevents duplicate events when using the centralized service.
  return if Current.paper_context? || Current.proof_attachment_service_context?

  # Set flag to prevent reentry
  @creating_proof_audit = true

  begin
    # Audit each proof type if it has changed
    audit_specific_proof_change('income')
    audit_specific_proof_change('residency')
  ensure
    # Reset the flag, even if an exception occurs
    @creating_proof_audit = false
  end
end

private

def audit_specific_proof_change(proof_type)
  return unless specific_proof_changed?(proof_type)

  create_audit_record_for_proof(proof_type)
end

def create_audit_record_for_proof(proof_type)
  attachment = public_send("#{proof_type}_proof")
  blob = attachment.blob
  actor = Current.user || user

  AuditEventService.log(
    action: "#{proof_type}_proof_submitted", # This event is suppressed when ProofAttachmentService is active
    actor: actor,
    auditable: self,
    metadata: {
      proof_type: proof_type,
      blob_id: blob&.id,
      content_type: blob&.content_type,
      byte_size: blob&.byte_size,
      filename: blob&.filename.to_s,
      ip_address: Current.ip_address,
      user_agent: Current.user_agent
    }
  )
end

# Note on Event Action Names:
# The `ProofAttachmentService` is the canonical source for audit events related to proof attachments.
# It creates events with the action `#{proof_type}_proof_attached`.
# The `ProofManageable` concern's `#{proof_type}_proof_submitted` events are suppressed
# when `ProofAttachmentService` is active to prevent duplication and ensure consistency.
```

### 7.2 · Review Audit Events

```ruby
# app/models/proof_review.rb
private

def handle_post_review_actions
  # ... (status checks and transaction)

  # Send appropriate notification based on status
  if status_rejected?
    send_notification('proof_rejected', :proof_rejected,
                      { proof_type: proof_type, rejection_reason: rejection_reason })
  else
    send_notification('proof_approved', :proof_approved, { proof_type: proof_type })
  end
end

# Creates a notification record and sends the email using the new NotificationService
# Notification failures don't interrupt the proof review process
def send_notification(action_name, _mail_method, metadata)
  # Log the audit event first
  AuditEventService.log(
    action: action_name,
    actor: admin,
    auditable: application,
    metadata: metadata
  )

  # Then, send the notification without the audit flag
  NotificationService.create_and_deliver!(
    type: action_name,
    recipient: application.user,
    actor: admin,
    notifiable: application,
    metadata: metadata,
    channel: :email
  )
rescue StandardError => e
  Rails.logger.error "Failed to send #{action_name} notification via NotificationService: #{e.message}"
  # Don't re-raise - notification errors shouldn't fail the whole operation
end
```

---

## 8 · Medical Certification Integration

### 8.1 · Automatic Medical Cert Requests

```ruby
# app/models/concerns/application_status_management.rb
after_save :handle_status_change, if: :saved_change_to_status?

private

# Handles transitions to specific statuses that trigger automated actions.
# Currently triggers the auto-request for medical certification when transitioning to 'awaiting_documents'.
def handle_status_change
  return unless status_previously_changed?(to: 'awaiting_documents')

  handle_awaiting_documents_transition
end

# Triggered when the application status transitions to 'awaiting_documents'.
# Checks if income and residency proofs are approved.
# If so, updates the medical certification status to 'requested' and sends an email to the medical provider.
def handle_awaiting_documents_transition
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

### 8.2 · Medical Cert as Proof Type

```ruby
# Medical certifications are treated as a special proof type
# with their own status field and workflow integration

# Check if medical certification is considered "complete" for application processing
# This is typically checked by looking at the medical_certification_status field directly.
# For example: application.medical_certification_status_received? || application.medical_certification_status_approved?

# This method is used internally by ApplicationStatusManagement for auto-approval
# It checks if all three required components (income, residency, medical cert) are approved
# (See ApplicationStatusManagement#all_requirements_met?)
def all_requirements_met?
  income_proof_status_approved? &&
    residency_proof_status_approved? &&
    medical_certification_status_approved?
end

# Check if medical certification is not required (i.e., not yet requested)
# This is typically checked by looking at the medical_certification_status field directly.
# For example: application.medical_certification_status_not_requested?
```

---

## 9 · Background Jobs & Monitoring

### 9.1 · Automated Monitoring

| Job | Purpose | Schedule |
|-----|---------|----------|
| **`ProofReviewReminderJob`** | Notify admins of stale reviews | Daily |
| **`ProofConsistencyCheckJob`** | Validate data integrity | Weekly |
| **`ProofAttachmentMetricsJob`**** | Monitor failure rates | Hourly |
| **`CleanupOldProofsJob`** | Archive old attachments | Daily |

### 9.2 · Failure Rate Monitoring

```ruby
# app/jobs/proof_attachment_metrics_job.rb
SUCCESS_RATE_THRESHOLD = 95.0 # Alert if success rate falls below 95%
MINIMUM_FAILURES_THRESHOLD = 5 # Only alert if we have at least 5 failures

def perform
  Rails.logger.info 'Analyzing Proof Submission Failure Rates'

  # Get recent proof submission events (last 24 hours)
  recent_events = Event.where(action: 'proof_submitted')
                       .where('created_at > ?', 24.hours.ago)

  total_submissions = recent_events.count
  failed_submissions = recent_events.where("metadata->>'success' = ?", 'false').count
  successful_submissions = total_submissions - failed_submissions

  # Calculate success rate
  success_rate = if total_submissions > 0
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

## 10 · Frontend Integration

### 10.1 · Stimulus Controllers

| Controller | Purpose | File Location |
|------------|---------|---------------|
| **`DocumentProofHandlerController`** | Admin proof accept/reject UI | `app/javascript/controllers/users/` |
| **`ProofStatusController`** | Show/hide sections based on status | `app/javascript/controllers/reviews/` |
| **`RejectionFormController`** | Dynamic rejection reason forms | `app/javascript/controllers/forms/` |

### 10.2 · Dynamic UI Behavior

```javascript
// app/javascript/controllers/reviews/proof_status_controller.js
toggle(event) {
  // Check for both "approved" and "accepted" values to support both proofs and medical certifications
  const isApproved = event.target.value === "approved" || event.target.value === "accepted"
  
  // Use setVisible utility for consistent visibility management
  this.withTarget('uploadSection', (target) => setVisible(target, isApproved));
  this.withTarget('rejectionSection', (target) => setVisible(target, !isApproved));
}
```

---

## 11 · Testing Patterns

### 11.1 · Service Testing

```ruby
# Focus on transaction safety and error handling
describe Applications::ProofReviewer do
  # Note: Notification failures do NOT roll back the ProofReview record or application status update
  # because NotificationService.create_and_deliver! rescues errors and ProofReview#send_notification
  # is called after ProofReview is saved.
  it 'creates a ProofReview record and updates application status on success' do
    expect { service.review(proof_type: 'income', status: 'approved') }
      .to change(ProofReview, :count).by(1)
    expect(@application.reload.income_proof_status_approved?).to be true
  end

  it 'does not roll back ProofReview on notification failure' do
    allow(NotificationService).to receive(:create_and_deliver!)
      .and_raise(StandardError) # Simulate notification failure

    expect { service.review(proof_type: 'income', status: 'approved') }
      .to change(ProofReview, :count).by(1) # ProofReview should still be created
    expect(@application.reload.income_proof_status_approved?).to be true # Application status should still be updated
  end

  it 'rolls back on critical database errors during review' do
    allow_any_instance_of(ProofReview).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)

    expect { service.review(proof_type: 'income', status: 'approved') }
      .to raise_error(ActiveRecord::RecordInvalid)
    expect(ProofReview.count).to eq(0) # Should not create a record
    expect(@application.reload.income_proof_status_not_reviewed?).to be true # Should not update status
  end
end
```

### 11.2 · Integration Testing

```ruby
# Test complete workflows end-to-end
describe 'Proof Review Workflow' do
  it 'handles complete approval process from constituent submission to admin approval' do
    # Setup: Create an application in a state ready for proof submission
    application = create(:application, :in_progress, user: constituent)
    # Ensure medical certification is approved for auto-approval to trigger
    application.update_column(:medical_certification_status, Application.medical_certification_statuses[:approved])

    # Constituent submits income proof
    # Use the correct route and parameters for resubmission
    post resubmit_proof_document_constituent_portal_application_path(application, proof_type: 'income'),
         params: { income_proof_upload: fixture_file_upload('test_proof.pdf', 'application/pdf') }

    # Constituent submits residency proof
    post resubmit_proof_document_constituent_portal_application_path(application, proof_type: 'residency'),
         params: { residency_proof_upload: fixture_file_upload('test_proof.pdf', 'application/pdf') }

    # Admin reviews and approves income proof
    # Use the correct route and action for admin review
    patch update_proof_status_admin_application_path(application),
          params: { proof_type: 'income', status: 'approved' }

    # Admin reviews and approves residency proof
    patch update_proof_status_admin_application_path(application),
          params: { proof_type: 'residency', status: 'approved' }

    # Verify application status is now approved (auto-approved)
    expect(application.reload.status_approved?).to be true

    # Verify notifications were sent (ProofReview model triggers these)
    expect(NotificationService).to have_received(:create_and_deliver!).with(
      type: 'proof_approved',
      recipient: application.user,
      actor: anything, # Can be admin or system
      notifiable: application,
      metadata: hash_including(proof_type: 'income')
    ).at_least(:once)

    expect(NotificationService).to have_received(:create_and_deliver!).with(
      type: 'proof_approved',
      recipient: application.user,
      actor: anything,
      notifiable: application,
      metadata: hash_including(proof_type: 'residency')
    ).at_least(:once)

    # Verify auto-approval event
    expect(Event.where(action: 'application_auto_approved', auditable: application)).to exist
  end
end
```

---

## 12 · Common Troubleshooting

### 12.1 · Status Inconsistencies

**Problem**: Application status doesn't match proof statuses  
**Solution**: Run `ProofConsistencyCheckJob` or use Rails console:

```ruby
# Fix inconsistent application (if proofs are approved but application status is not)
# If an application's proof statuses (income, residency, medical certification) are all 'approved'
# but the application status itself is not 'approved', you can trigger the auto-approval logic
# by ensuring the relevant proof statuses are correctly set and then saving the application.
# The `ApplicationStatusManagement#auto_approve_if_eligible` callback will then re-evaluate.

# Example: If income_proof_status was manually changed in DB and auto-approval didn't trigger
app = Application.find(123)
# Ensure all relevant proof statuses are correctly set to approved
app.income_proof_status = :approved
app.residency_proof_status = :approved
app.medical_certification_status = :approved
app.save! # This will trigger the `auto_approve_if_eligible` callback if conditions are met

# Alternatively, an administrator can manually approve the application via the UI or console:
# app.approve!(user: User.find_by(email: 'admin@example.com'))
```

### 12.2 · Missing Audit Trails

**Problem**: Proof submissions not creating audit events  
**Check**: `ProofManageable#create_proof_submission_audit` method and `@creating_proof_audit` flag

```ruby
# app/models/concerns/proof_manageable.rb
def create_proof_submission_audit
  # Guard clause to prevent infinite recursion
  return if @creating_proof_audit
  return unless proof_attachments_changed?
  
  # Skip if ProofAttachmentService is handling the audit (paper context)
  return if Current.paper_context?

  # Set flag to prevent reentry
  @creating_proof_audit = true

  begin
    # Audit each proof type if it has changed
    audit_specific_proof_change('income')
    audit_specific_proof_change('residency')
  ensure
    # Reset the flag, even if an exception occurs
    @creating_proof_audit = false
  end
end

private

def audit_specific_proof_change(proof_type)
  return unless specific_proof_changed?(proof_type)

  create_audit_record_for_proof(proof_type)
end

def create_audit_record_for_proof(proof_type)
  attachment = public_send("#{proof_type}_proof")
  blob = attachment.blob
  actor = Current.user || user

  AuditEventService.log(
    action: "#{proof_type}_proof_submitted",
    actor: actor,
    auditable: self,
    metadata: {
      proof_type: proof_type,
      blob_id: blob&.id,
      content_type: blob&.content_type,
      byte_size: blob&.byte_size,
      filename: blob&.filename.to_s,
      ip_address: Current.ip_address,
      user_agent: Current.user_agent
    }
  )
end
```

### 12.3 · Email Processing Failures

**Problem**: Emailed proofs not being processed  
**Debug**: Check `/rails/conductor/action_mailbox/inbound_emails` and mailbox routing logic

---

## 13 · Future Enhancements

### 13.1 · Planned Improvements

- **DocuSeal Integration**: Digital signature workflow for medical certifications
- **Mobile Upload Optimization**: Enhanced mobile photo capture

### 13.2 · Technical Debt

- **Proof Type Enumeration**: Centralize proof type definitions
- **Status Field Consolidation**: Consider JSON column for complex statuses
- **Notification Template Standardization**: Move all messages to `NotificationComposer`

---

**Tools**: Admin dashboard (`/admin/applications`) · Mailbox conductor (`/rails/conductor/action_mailbox`) · Audit logs (`/admin/events`) · Background job monitoring (`/admin/jobs`)
