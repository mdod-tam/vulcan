# frozen_string_literal: true

# Coordinates certification attachment, status history, audit, and notifications.
# Staff uploads pass through UploadedDocument.
# Provider submissions share primary/additional placement rules.
class MedicalCertificationAttachmentService
  # Staff may not replace a certification that awaits review or is already approved
  class StaffUploadNotAllowed < StandardError
    def initialize(msg = 'This certification is awaiting review or already approved.')
      super
    end
  end

  # Updates only the status of a medical certification without touching the attachment
  #
  # @param application [Application] The application whose certification status to update
  # @param status [Symbol] The status to set (:approved, :rejected, :received)
  # @param admin [User] The admin user performing this action
  # @param submission_method [Symbol] The method of submission (:fax, :email, :portal, etc.)
  # @param metadata [Hash] Additional metadata to store with the operation
  #
  # @return [Hash] Result hash with :success, :error, and :duration_ms keys
  def self.update_certification_status(application:, status:, admin:, submission_method: :admin_review, metadata: {})
    start_time = Time.current
    result = { success: false, error: nil, duration_ms: 0 }

    begin
      raise 'Cannot update certification status: No certification is attached' unless application.medical_certification.attached?

      Rails.logger.info "Updating disability certification status to #{status} for application #{application.id}"

      update_certification_status_only(application, status, admin, submission_method, metadata)

      result[:success] = true
      result[:status] = status.to_s
    rescue StandardError => e
      record_failure(application, e, admin, submission_method, metadata)
      result[:error] = e
    ensure
      result[:duration_ms] = ((Time.current - start_time) * 1000).round
      record_metrics(result, status)
    end

    result
  end

  # Staff and provider submissions take the same application lock.
  # Staff uploads refuse a received or approved certification before file intake.
  # UploadedDocument checks the file before attachment.
  # StaffUploadNotAllowed and UploadedDocument::Refused leave the certification unchanged.
  def self.attach_certification(application:, blob_or_file:, status: :approved,
                                admin: nil, submission_method: :admin_upload, metadata: {})
    execute_with_timing(status) do
      application.with_lock do
        raise StaffUploadNotAllowed unless application.staff_certification_upload_allowed?

        blob = UploadedDocument.resolve!(blob_or_file, record: application, name: 'medical_certification')
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
      retention_reason = submission_retention_reason(application, requested_at)
      if retention_reason.nil?
        # Secure forms validate manual uploads through UploadedDocument.
        # DocuSeal supplies a generated document under its own contract.
        result = execute_with_timing(:received) do
          process_attachment(application: application, blob: blob, status: :received, admin: admin,
                             submission_method: submission_method, metadata: metadata)
        end
        next result.merge(placement: :primary)
      end

      blob.update!(metadata: blob.metadata.merge('retention_reason' => retention_reason))
      application.additional_medical_certifications.attach(blob)
      {
        success: application.additional_medical_certifications.attachments.any? { |attachment| attachment.blob_id == blob.id },
        placement: :additional,
        additional_blob_id: blob.id,
        retention_reason: retention_reason
      }
    end
  end

  def self.submission_retention_reason(application, requested_at)
    case application.medical_certification_status.to_s
    when 'approved' then 'certification_approved'
    when 'received' then 'certification_received'
    when 'rejected'
      rejected_at = latest_rejection_at(application)
      correction = requested_at.present? && rejected_at.present? && requested_at > rejected_at
      correction ? nil : 'request_predates_rejection'
    end
  end

  def self.latest_rejection_at(application)
    ApplicationStatusChange.where(application: application, change_type: 'medical_certification', to_status: 'rejected')
                           .maximum(:changed_at) || application.medical_certification_verified_at
  end

  # Reject a medical certification without requiring a file attachment
  def self.reject_certification(application:, admin:, reason:, notes: nil, # rubocop:disable Metrics/ParameterLists
                                reason_code: nil, submission_method: :admin_review, metadata: {})
    rejection_params = {
      application: application,
      admin: admin,
      reason: reason,
      notes: notes,
      reason_code: reason_code,
      submission_method: submission_method,
      metadata: metadata
    }

    execute_with_timing(:rejected) do
      process_rejection(rejection_params)
    end
  end

  def self.attachment_verified?(application)
    if application.medical_certification.attached?
      attachment = application.medical_certification.attachment
      Rails.logger.info "Attachment confirmed - ID: #{attachment.id}, Blob ID: #{attachment.blob_id}"
      return true
    end

    # A stale attachment association can miss a stored record.
    # Check the database before reporting failure.
    attachment_exists = ActiveStorage::Attachment.exists?(record_type: 'Application',
                                                          record_id: application.id,
                                                          name: 'medical_certification')

    return false unless attachment_exists

    Rails.logger.warn 'Attachment exists in DB but not detected in model - forcing reset'
    application.medical_certification.reset
    true
  end

  # Updates only the status fields and creates audit records without touching the attachment
  def self.update_certification_status_only(application, status, admin, submission_method, metadata)
    ActiveRecord::Base.transaction do
      old_status = application.medical_certification_status || 'requested'

      Rails.logger.info "[MedicalCertService] Updating status from #{old_status} to #{status} for app #{application.id}"

      # update_columns bypasses Application validations and callbacks.
      # This service owns status history, audit, notifications, and approved-workflow reconciliation.
      # Before you add callback-dependent behavior, remove this bypass or extend the manual bookkeeping.
      update_result = application.update_columns( # rubocop:disable Rails/SkipsModelValidations
        medical_certification_status: status.to_s,
        medical_certification_verified_at: Time.current,
        medical_certification_verified_by_id: admin&.id,
        updated_at: Time.current
      )

      Rails.logger.info "[MedicalCertService] update_columns returned: #{update_result}"

      application.reload

      Rails.logger.info "Updated disability certification status to #{status} for application #{application.id}"

      ApplicationStatusChange.create!(
        application: application,
        user: admin,
        from_status: old_status,
        to_status: status.to_s,
        change_type: 'medical_certification',
        metadata: {
          change_type: 'medical_certification',
          submission_method: submission_method.to_s,
          verified_at: Time.current.iso8601,
          verified_by_id: admin&.id
        }
      )

      AuditEventService.log(
        action: 'medical_certification_status_changed',
        actor: admin,
        auditable: application,
        metadata: {
          old_status: application.medical_certification_status_was || 'requested',
          new_status: status.to_s,
          change_type: 'medical_certification'
        }
      )

      action_mapping = {
        approved: 'medical_certification_approved',
        rejected: 'medical_certification_rejected',
        received: 'medical_certification_received'
      }

      notification_action = action_mapping[status.to_sym]

      # Only approved certifications trigger downstream approval.
      # Received and rejected certifications still need review or follow-up.
      if status.to_sym == :approved
        application.reload
        actor = admin.presence || application.user
        application.reconcile_workflow_state!(actor: actor, trigger: :medical_certification_approved) if actor.present?
      end

      if notification_action.present?
        NotificationService.create_and_deliver!(
          type: notification_action,
          recipient: application.user,
          actor: admin,
          notifiable: application,
          metadata: metadata,
          channel: :email,
          deliver: notification_action != 'medical_certification_approved'
        )
      end
    end
  end

  def self.record_failure(application, error, admin, submission_method, _metadata)
    Rails.logger.error "Disability certification attachment error: #{error.message}"
    Rails.logger.error error.backtrace.join("\n")

    begin
      AuditEventService.log(
        action: 'medical_certification_attachment_failed',
        actor: admin,
        auditable: application,
        metadata: {
          error_class: error.class.name,
          error_message: error.message,
          submission_method: submission_method.to_s
        }
      )
    rescue StandardError => e
      # Failure reporting must not replace the original error.
      Rails.logger.error "Failed to record audit for failure: #{e.message}"
    end
  rescue StandardError => e
    Rails.logger.error "Failed to record disability certification failure: #{e.message}"
  end

  def self.record_metrics(result, status)
    log_operation_result(result, status)
    context = build_metrics_context(result, status)
    log_metrics(context)
  rescue StandardError => e
    Rails.logger.error "Failed to record disability certification metrics: #{e.message}"
  end

  def self.execute_with_timing(status)
    start_time = Time.current
    result = { success: false, error: nil, duration_ms: 0 }

    begin
      payload = yield
      result.merge!(payload) if payload.is_a?(Hash)
      result[:success] = true
    rescue StandardError => e
      result[:error] = e
      raise
    ensure
      result[:duration_ms] = ((Time.current - start_time) * 1000).round
      record_metrics(result, status)
    end

    result
  end

  # Main attachment processing logic
  def self.process_attachment(params)
    blob_size = params[:blob].byte_size

    perform_attachment(params[:application], params[:blob])
    update_certification_status_only(params[:application], params[:status], params[:admin],
                                     params[:submission_method], params[:metadata])
    verify_final_attachment(params[:application])

    { blob_size: blob_size, status: params[:status].to_s }
  end

  # Handles rejection processing with transaction
  def self.process_rejection(params)
    ActiveRecord::Base.transaction do
      params[:resolved_reason] = resolve_rejection_reason_text(params)
      update_rejection_status(params)
      upsert_medical_rejection_review(params)
      create_rejection_audit_trail(params)
      notification = send_rejection_notification(params)
      { notification_id: notification&.id }
    end
  end

  # Rejection helper methods
  def self.update_rejection_status(params)
    old_status = params[:application].medical_certification_status || 'requested'
    params[:old_status] = old_status

    # This branch shares the callback bypass in update_certification_status_only
    # and must maintain its own audit trail.
    update_attrs = {
      medical_certification_status: 'rejected',
      medical_certification_verified_at: Time.current,
      medical_certification_verified_by_id: params[:admin].id,
      updated_at: Time.current
    }

    params[:application].update_columns(**update_attrs) # rubocop:disable Rails/SkipsModelValidations
    params[:application].reload
  end

  def self.upsert_medical_rejection_review(params)
    app = params[:application]
    review = app.proof_reviews.find_or_initialize_by(
      proof_type: :medical_certification,
      status: :rejected
    )

    review.assign_attributes(
      admin: params[:admin],
      rejection_reason: params[:resolved_reason],
      rejection_reason_code: params[:reason_code].presence,
      notes: params[:notes]
    )
    review.reviewed_at = Time.current unless review.new_record?
    review.save!
  end

  def self.create_rejection_audit_trail(params)
    app = params[:application]
    admin = params[:admin]

    ApplicationStatusChange.create!(
      application: app,
      user: admin,
      from_status: params[:old_status] || 'requested',
      to_status: 'rejected',
      change_type: 'medical_certification',
      metadata: {
        change_type: 'medical_certification',
        submission_method: params[:submission_method],
        verified_at: Time.current.iso8601,
        verified_by_id: admin.id,
        rejection_reason: params[:resolved_reason],
        notes: params[:notes]
      },
      notes: params[:notes]
    )

    AuditEventService.log(
      actor: admin,
      action: 'medical_certification_status_changed',
      auditable: app,
      metadata: {
        application_id: app.id,
        old_status: app.medical_certification_status_was || 'requested',
        new_status: 'rejected',
        timestamp: Time.current.iso8601,
        change_type: 'medical_certification',
        reason: params[:resolved_reason]
      }
    )
  end

  def self.send_rejection_notification(params)
    NotificationService.create_and_deliver!(
      type: 'medical_certification_rejected',
      recipient: params[:application].user,
      actor: params[:admin],
      notifiable: params[:application],
      metadata: {
        'rejection_reason' => params[:resolved_reason],
        'notes' => params[:notes]
      },
      channel: :email,
      deliver: false
    )
  end

  def self.resolve_rejection_reason_text(params)
    RejectionReason.resolve_text(
      code: params[:reason_code].presence,
      proof_type: 'medical_certification',
      fallback: params[:reason]
    )
  end

  # Metrics helper methods
  def self.log_operation_result(result, status)
    if result[:success]
      Rails.logger.info "Medical certification #{status} completed in #{result[:duration_ms]}ms"
    else
      Rails.logger.error "Medical certification #{status} failed in #{result[:duration_ms]}ms: #{result[:error]&.message}"
    end
  end

  def self.build_metrics_context(result, status)
    context = {
      status: status,
      success: result[:success],
      duration_ms: result[:duration_ms],
      environment: Rails.env,
      transaction_id: SecureRandom.uuid
    }

    add_error_context(context, result[:error]) if result[:error]
    context
  end

  def self.add_error_context(context, error)
    context[:error_class] = error.class.name
    context[:error_message] = error.message
    context[:error_backtrace] = error.backtrace.first(3) if error.backtrace
  end

  def self.perform_attachment(application, attachment_param)
    Rails.logger.info "EXECUTING ATTACHMENT: medical_certification to application #{application.id}"

    fresh_application = Application.unscoped.find(application.id)
    fresh_application.medical_certification.attach(attachment_param)

    # Verify the persisted attachment rather than relying on attach's return value.
    Rails.logger.error "Failed to attach certification: #{fresh_application.errors.full_messages.join(', ')}" unless fresh_application.medical_certification.attached?

    reloaded_app = Application.unscoped.find(application.id)
    raise 'Failed to verify attachment: medical_certification not attached after direct attachment' unless attachment_verified?(reloaded_app)

    Rails.logger.info "Successfully verified medical certification attachment for application #{application.id}"
    reloaded_app
  end

  def self.verify_final_attachment(application)
    application.reload
    raise 'Critical error: Attachment disappeared after status update' unless application.medical_certification.attached?
  end

  def self.log_metrics(context)
    Rails.logger.info("METRICS: medical_certification #{context.to_json}")
  end
end
