# frozen_string_literal: true

# Coordinates certification attachment, status history, audit, and notifications.
# Staff uploads pass through UploadedDocument.
# Provider submissions share primary/additional placement rules.
class DisabilityCertificationAttachmentService
  # Staff may not replace a certification that awaits review or is already approved
  class StaffUploadNotAllowed < StandardError
    def initialize(msg = 'This certification is awaiting review or already approved.')
      super
    end
  end

  # Changes the certification status. The attachment does not change.
  # Errors are recorded and returned, not raised.
  #
  # @param application [Application] the application to update
  # @param status [Symbol] :approved or :received. Rejections use reject_certification.
  # @param admin [User] the admin who makes the change
  # @param submission_method [Symbol] the submission channel
  # @param metadata [Hash] additional operation metadata
  # @param decision_key [String, nil] Stable decision identifier, required for approval
  # @param reviewed_blob_id [Integer, nil] Reviewed document identifier, required for approval
  # @return [Hash] :success, :error, :duration_ms, and :status on success
  # rubocop:disable-next Metrics/ParameterLists -- Approval identity and target are explicit beside the existing status inputs.
  def self.update_certification_status(application:, status:, admin:, submission_method: :admin_review, metadata: {},
                                       decision_key: nil, reviewed_blob_id: nil)
    on_error = ->(error) { record_failure(application, error, admin, submission_method, metadata) }

    result = AttachmentOperation.measure("Disability certification #{status}", on_error: on_error) do |outcome|
      raise ArgumentError, 'Use reject_certification to record a rejection' if status.to_s == 'rejected'

      if status.to_s == 'approved'
        outcome.merge!(approve_existing_certification(application, admin, decision_key, reviewed_blob_id, submission_method, metadata))
      else
        application.with_lock do
          require_certification!(application)
          update_certification_status_only(application, status, admin, submission_method, metadata)
        end
      end

      outcome[:success] = true
      outcome[:status] = status.to_s
    end
    result[:commit_state] = :unknown if result[:error].is_a?(Applications::ReviewCommit::Unconfirmed)
    result
  end

  def self.approve_existing_certification(application, admin, decision_key, reviewed_blob_id, submission_method, metadata)
    review = nil
    commit = Applications::ReviewCommit.new(application: application, subject: 'certification approval', again: 'approving it again') do
      {
        review: application.proof_reviews.find_by(decision_key: decision_key)&.attributes_for_database,
        application: Application.where(id: application.id).pick(:status, :disability_certification_status,
                                                                :disability_certification_verified_at, :disability_certification_verified_by_id),
        history: ApplicationStatusChange.where(application_id: application.id).count
      }
    end
    recorded = false
    commit.run(on_committed: ->(error) { review&.log_follow_up_failure(error) }) do
      commit.transaction do
        decision = ProofReview.record_decision!(application: application, admin: admin, decision_key: decision_key,
                                                reviewed_blob_id: reviewed_blob_id, proof_type: :disability_certification, status: :approved) do |new_review|
          DocumentScan.require_clean!(require_certification!(application).blob)
          new_review.record!(submission_method: ProofReview.submission_methods.key?(submission_method.to_s) ? submission_method : nil)
          update_certification_status_only(application, :approved, admin, submission_method, metadata.merge(proof_review_id: new_review.id))
        end
        review = decision.review
        recorded = decision.recorded
      end
    end
    { proof_review: review, recorded: recorded, warning: commit.warning }.compact
  end

  def self.require_certification!(application)
    attachment = application.disability_certification
    raise 'Cannot update certification status: No certification is attached' unless attachment.attached?

    attachment
  end
  private_class_method :approve_existing_certification, :require_certification!

  # Staff and provider submissions take the same application lock.
  # Staff uploads refuse a received or approved certification before file intake.
  # UploadedDocument checks the file before attachment.
  # StaffUploadNotAllowed and UploadedDocument::Refused leave the certification unchanged.
  def self.attach_certification(application:, blob_or_file:, status: :approved,
                                admin: nil, submission_method: :admin_upload, metadata: {})
    execute_with_timing(status) do
      application.with_lock do
        raise StaffUploadNotAllowed unless application.staff_certification_upload_allowed?

        blob = UploadedDocument.resolve!(blob_or_file, record: application, name: 'disability_certification', scan_owner: admin)
        process_attachment(application: application, blob: blob, status: status, admin: admin,
                           submission_method: submission_method, metadata: metadata)
      end
    end
  end

  # Reasons for retaining a provider submission as an additional certification.
  RETENTION_REASONS = %w[certification_approved certification_received request_predates_rejection].freeze

  # Places submissions from DocuSeal and secure provider forms under the same rules.
  # - approved or received: retain as additional and keep the current status.
  # - rejected: replace the primary only when the request follows the latest rejection.
  #   Otherwise, retain it as additional.
  # - not_requested or requested: use as primary.
  # Retained submissions carry a reason for staff review.
  #
  # @return [Hash] :success, :placement (:primary or :additional), :additional_blob_id, :retention_reason
  def self.accept_submission(application:, blob:, submission_method:, requested_at:, admin:, metadata: {})
    application.with_lock do
      DocumentScan.require_clean!(blob)
      retention_reason = submission_retention_reason(application, requested_at)
      if retention_reason.nil?
        result = execute_with_timing(:received) do
          process_attachment(application: application, blob: blob, status: :received, admin: admin,
                             submission_method: submission_method, metadata: metadata)
        end
        next result.merge(placement: :primary)
      end

      blob.update!(metadata: blob.metadata.merge('retention_reason' => retention_reason))
      application.additional_disability_certifications.attach(blob)
      {
        success: application.additional_disability_certifications.attachments.any? { |attachment| attachment.blob_id == blob.id },
        placement: :additional,
        additional_blob_id: blob.id,
        retention_reason: retention_reason
      }
    end
  end

  def self.submission_retention_reason(application, requested_at)
    case application.disability_certification_status.to_s
    when 'approved' then 'certification_approved'
    when 'received' then 'certification_received'
    when 'rejected'
      rejected_at = latest_rejection_at(application)
      correction = requested_at.present? && rejected_at.present? && requested_at > rejected_at
      correction ? nil : 'request_predates_rejection'
    end
  end

  def self.latest_rejection_at(application)
    ApplicationStatusChange.where(application: application, change_type: 'disability_certification', to_status: 'rejected')
                           .maximum(:changed_at) || application.disability_certification_verified_at
  end

  # Rejects the certification. An attached file is not necessary.
  def self.reject_certification(application:, admin:, reason:, decision_key:, reviewed_blob_id:, notes: nil, # rubocop:disable Metrics/ParameterLists
                                reason_code: nil, submission_method: :admin_review, metadata: {})
    rejection_params = {
      application: application,
      admin: admin,
      reason: reason,
      decision_key: decision_key,
      reviewed_blob_id: reviewed_blob_id,
      notes: notes,
      reason_code: reason_code,
      submission_method: submission_method,
      metadata: metadata
    }

    execute_with_timing(:rejected) do
      process_rejection(rejection_params)
    end
  end

  # Writes the status, status history, audit event, and notification. The attachment does not change.
  def self.update_certification_status_only(application, status, admin, submission_method, metadata)
    raise ArgumentError, 'Use reject_certification to record a rejection' if status.to_s == 'rejected'

    ActiveRecord::Base.transaction do
      Rails.logger.info "Updating disability certification status to #{status} for application #{application.id}"

      record_verified_status!(application, status, admin, submission_method: submission_method.to_s, metadata: metadata)

      action_mapping = {
        approved: 'disability_certification_approved',
        received: 'disability_certification_received'
      }

      notification_action = action_mapping[status.to_sym]

      # Only approved certifications trigger downstream approval.
      # Received and rejected certifications still need review or follow-up.
      if status.to_sym == :approved
        application.reload
        actor = admin.presence || application.user
        application.reconcile_workflow_state!(actor: actor, trigger: :disability_certification_approved) if actor.present?
      end

      if notification_action.present?
        NotificationService.create_and_deliver!(
          type: notification_action,
          recipient: application.user,
          actor: admin,
          notifiable: application,
          metadata: metadata,
          channel: :email,
          deliver: notification_action != 'disability_certification_approved'
        )
      end
    end
  end

  # A review outcome records who verified the certification and when, whatever the outcome.
  def self.record_verified_status!(application, status, admin, submission_method:, metadata: {}, notes: nil)
    verified_at = Time.current
    application.transition_disability_certification_status!(
      status,
      actor: admin,
      notes: notes,
      attributes: { disability_certification_verified_at: verified_at, disability_certification_verified_by_id: admin&.id },
      metadata: { submission_method: submission_method, verified_at: verified_at.iso8601, verified_by_id: admin&.id }.merge(metadata)
    )
  end

  def self.record_failure(application, error, admin, submission_method, _metadata)
    Rails.logger.error "Disability certification attachment error for application #{application.id}: #{error.class.name}"

    begin
      AuditEventService.log(
        action: 'disability_certification_attachment_failed',
        actor: admin,
        auditable: application,
        metadata: {
          error_class: error.class.name,
          submission_method: submission_method.to_s
        }
      )
    rescue StandardError => e
      # Failure reporting must not replace the original error.
      Rails.logger.error "Failed to record audit for failure: #{e.class.name}"
    end
  rescue StandardError => e
    Rails.logger.error "Failed to record disability certification failure: #{e.class.name}"
  end

  # Returns the result with the block's payload merged in. A failure is raised, not returned.
  def self.execute_with_timing(status)
    AttachmentOperation.measure("Disability certification #{status}", reraise: true) do |result|
      payload = yield
      result.merge!(payload) if payload.is_a?(Hash)
      result[:success] = true
    end
  end

  def self.process_attachment(params)
    blob_size = params[:blob].byte_size

    perform_attachment(params[:application], params[:blob])
    update_certification_status_only(params[:application], params[:status], params[:admin],
                                     params[:submission_method], params[:metadata])
    AttachmentOperation.verify_attached!(params[:application], :disability_certification)

    { blob_size: blob_size, status: params[:status].to_s }
  end

  def self.process_rejection(params)
    notification = nil
    decision = ProofReview.record_decision!(
      application: params[:application], decision_key: params[:decision_key], reviewed_blob_id: params[:reviewed_blob_id],
      proof_type: :disability_certification, status: :rejected, admin: params[:admin],
      rejection_reason: params[:reason], rejection_reason_code: params[:reason_code], notes: params[:notes]
    ) do |review|
      params[:resolved_reason] = resolve_rejection_reason_text(params)
      review.record!(
        rejection_reason: params[:resolved_reason], rejection_reason_code: params[:reason_code].presence,
        submission_method: ProofReview.submission_methods.key?(params[:submission_method].to_s) ? params[:submission_method] : nil
      )
      record_verified_status!(
        params[:application], :rejected, params[:admin],
        submission_method: params[:submission_method],
        metadata: { rejection_reason: params[:resolved_reason] },
        notes: params[:notes]
      )
      params[:proof_review] = review
      notification = send_rejection_notification(params)
    end
    notification ||= Notification.where(action: 'disability_certification_rejected', notifiable: params[:application])
                                 .find_by("metadata->>'proof_review_id' = ?", decision.review.id.to_s)
    { notification_id: notification&.id, proof_review: decision.review, recorded: decision.recorded }
  end

  def self.send_rejection_notification(params)
    NotificationService.create_and_deliver!(
      type: 'disability_certification_rejected',
      recipient: params[:application].user,
      actor: params[:admin],
      notifiable: params[:application],
      metadata: {
        'proof_review_id' => params[:proof_review].id,
        'rejection_reason' => params[:resolved_reason],
        'notes' => params[:notes]
      },
      channel: :email,
      deliver: false
    )
  rescue ActiveRecord::RecordInvalid
    # NotificationService records the failure; the reviewer reports missing tracking after commit.
    nil
  end

  def self.resolve_rejection_reason_text(params)
    RejectionReason.resolve_text(
      code: params[:reason_code].presence,
      proof_type: 'disability_certification',
      fallback: params[:reason],
      application: params[:application]
    )
  end

  # Attaches to a fresh record and confirms from the database that the file is stored, not from attach's return value.
  def self.perform_attachment(application, attachment_param)
    fresh_application = Application.unscoped.find(application.id)
    fresh_application.disability_certification.attach(attachment_param)
    AttachmentOperation.verify_attached!(fresh_application, :disability_certification)
  end
end
