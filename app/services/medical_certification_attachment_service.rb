# frozen_string_literal: true

# Service to handle medical certification attachments with consistent transaction handling
#
# This service follows the same pattern as ProofAttachmentService but is specifically
# tailored for handling medical certification attachments, ensuring reliable uploads
# and consistent status tracking.
#
# Key responsibilities:
# 1. Handle blob/file conversion for different input types
# 2. Provide a unified interface for attaching medical certifications
# 3. Maintain audit records for all attachment operations
# 4. Provide consistent error handling and logging
class MedicalCertificationAttachmentService
  # Updates only the status of a medical certification without touching the attachment
  #
  # @param application [Application] The application whose certification status to update
  # @param status [Symbol] The status to set (:accepted, :rejected, :received)
  # Using 'approved' consistently throughout the codebase to match the Application model enum
  # @param admin [User] The admin user performing this action
  # @param submission_method [Symbol] The method of submission (:fax, :email, :portal, etc.)
  # @param metadata [Hash] Additional metadata to store with the operation
  #
  # @return [Hash] Result hash with :success, :error, and :duration_ms keys
  def self.update_certification_status(application:, status:, admin:, submission_method: :admin_review, metadata: {})
    start_time = Time.current
    result = { success: false, error: nil, duration_ms: 0 }

    begin
      # Verify the existing certification is attached before proceeding
      raise 'Cannot update certification status: No certification is attached' unless application.medical_certification.attached?

      Rails.logger.info "Updating disability certification status to #{status} for application #{application.id}"

      # Update status and create audit records in a single transaction
      update_certification_status_only(application, status, admin, submission_method, metadata)

      # Set success outcome
      result[:success] = true
      result[:status] = status.to_s
    rescue StandardError => e
      # Track failure with detailed information
      record_failure(application, e, admin, submission_method, metadata)
      result[:error] = e
    ensure
      result[:duration_ms] = ((Time.current - start_time) * 1000).round
      record_metrics(result, status)
    end

    result
  end

  # Attaches a medical certification document to an application
  def self.attach_certification(application:, blob_or_file:, status: :approved,
                                admin: nil, submission_method: :admin_upload, metadata: {})
    attachment_params = {
      application: application,
      blob_or_file: blob_or_file,
      status: status,
      admin: admin,
      submission_method: submission_method,
      metadata: metadata
    }

    execute_with_timing(status) do
      process_attachment(attachment_params)
    end
  end

  # Reject a medical certification without requiring a file attachment
  def self.reject_certification(application:, admin:, reason:, notes: nil,
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

  def self.process_attachment_param(blob_or_file)
    log_input_details(blob_or_file)

    return process_string_input(blob_or_file) if blob_or_file.is_a?(String) && blob_or_file.present?
    return process_parameters(blob_or_file) if action_controller_parameters?(blob_or_file)
    return process_blob(blob_or_file) if blob_or_file.is_a?(ActiveStorage::Blob)
    return process_uploaded_file(blob_or_file) if uploaded_file?(blob_or_file)

    # Fallback for other types
    log_fallback_details(blob_or_file)
    blob_or_file
  end

  def self.attachment_verified?(application)
    # Check if the attachment is present
    if application.medical_certification.attached?
      attachment = application.medical_certification.attachment
      Rails.logger.info "Attachment confirmed - ID: #{attachment.id}, Blob ID: #{attachment.blob_id}"
      return true
    end

    # Try one last manual DB query to check if attachment exists
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
      # Capture the old status before updating
      old_status = application.medical_certification_status || 'requested'

      # Update certification status
      application.update!(
        medical_certification_status: status.to_s,
        medical_certification_verified_at: Time.current,
        medical_certification_verified_by_id: admin&.id
      )

      Rails.logger.info "Updated disability certification status to #{status} for application #{application.id}"

      # Create ApplicationStatusChange record
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

      # Create event for audit trail
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

      # Create notification if needed using centralized service
      action_mapping = {
        approved: 'medical_certification_approved',
        rejected: 'medical_certification_rejected',
        received: 'medical_certification_received'
      }

      # Get the notification action name based on the status
      notification_action = action_mapping[status.to_sym]

      # Create notification if we have a valid action for this status
      if notification_action.present?
        NotificationService.create_and_deliver!(
          type: notification_action,
          recipient: application.user,
          actor: admin,
          notifiable: application,
          metadata: metadata,
          channel: :email
        )
      end
    end
  end

  def self.record_failure(application, error, admin, submission_method, _metadata)
    Rails.logger.error "Disability certification attachment error: #{error.message}"
    Rails.logger.error error.backtrace.join("\n")

    begin
      # Create an event to track the error
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
      # Don't let audit failures affect the main flow
      Rails.logger.error "Failed to record audit for failure: #{e.message}"
    end
  rescue StandardError => e
    # Try logging if even the failure tracking fails
    Rails.logger.error "Failed to record disability certification failure: #{e.message}"
  end

  def self.record_metrics(result, status)
    log_operation_result(result, status)
    context = build_metrics_context(result, status)
    log_metrics(context)
  rescue StandardError => e
    Rails.logger.error "Failed to record disability certification metrics: #{e.message}"
  end

  # Common timing wrapper for operations
  def self.execute_with_timing(status)
    start_time = Time.current
    result = { success: false, error: nil, duration_ms: 0 }

    begin
      yield
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
    blob_size = calculate_blob_size(params[:blob_or_file])
    log_attachment_context(params)

    attachment_param = process_attachment_param(params[:blob_or_file])
    perform_attachment(params[:application], attachment_param)
    update_certification_status_only(params[:application], params[:status], params[:admin],
                                     params[:submission_method], params[:metadata])
    verify_final_attachment(params[:application])

    { blob_size: blob_size, status: params[:status].to_s }
  end

  # Handles rejection processing with transaction
  def self.process_rejection(params)
    ActiveRecord::Base.transaction do
      update_rejection_status(params)
      create_rejection_audit_trail(params)
      send_rejection_notification(params)
    end
  end

  # Rejection helper methods
  def self.update_rejection_status(params)
    # Capture the old status before updating
    old_status = params[:application].medical_certification_status || 'requested'
    params[:old_status] = old_status

    update_attrs = {
      medical_certification_status: 'rejected',
      medical_certification_verified_at: Time.current,
      medical_certification_verified_by_id: params[:admin].id,
      medical_certification_rejection_reason: params[:reason]
    }
    update_attrs[:medical_certification_rejection_reason_code] = params[:reason_code] if params[:reason_code].present?

    params[:application].update!(update_attrs)
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
        rejection_reason: params[:reason],
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
        reason: params[:reason]
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
        'reason' => params[:reason],
        'notes' => params[:notes]
      },
      channel: :email
    )
  end

  # Input processing helper methods
  def self.log_input_details(blob_or_file)
    Rails.logger.info "DISABILITY CERTIFICATION ATTACHMENT INPUT: Type=#{blob_or_file.class.name}"
    Rails.logger.info "DISABILITY CERTIFICATION BLOB OR FILE VALUE: #{blob_or_file.to_s[0..100]}" if blob_or_file.respond_to?(:to_s)
    safe_inspect(blob_or_file)
  end

  def self.safe_inspect(blob_or_file)
    return unless blob_or_file.respond_to?(:inspect)

    inspection = blob_or_file.inspect[0..200]
    Rails.logger.info "DISABILITY CERTIFICATION ATTACHMENT INSPECTION: #{inspection}"
  rescue StandardError => e
    Rails.logger.info "Could not inspect input: #{e.message}"
  end

  def self.process_string_input(blob_or_file)
    Rails.logger.info "Processing string input as potential SignedID: #{blob_or_file[0..20]}..."
    validate_signed_id_for_logging(blob_or_file)
    blob_or_file
  end

  def self.validate_signed_id_for_logging(blob_or_file)
    blob = ActiveStorage::Blob.find_signed(blob_or_file)
    Rails.logger.info "Confirmed string is a valid signed ID: blob_id=#{blob.id}, filename=#{blob.filename}" if blob.present?
  rescue StandardError => e
    Rails.logger.info "Note: String parameter validation error: #{e.message}"
  end

  def self.process_parameters(blob_or_file)
    Rails.logger.info 'Processing ActionController::Parameters from direct upload'
    extract_signed_id_from_parameters(blob_or_file) || blob_or_file
  end

  def self.extract_signed_id_from_parameters(params)
    return params[:signed_id] if params[:signed_id].present?
    return params['signed_id'] if params['signed_id'].present?
    return params[:blob_signed_id] if params.key?(:blob_signed_id)

    find_signed_id_in_parameters(params)
  end

  def self.find_signed_id_in_parameters(params)
    return nil unless params.respond_to?(:each)

    params.each do |key, value|
      next unless value.is_a?(String) && value.start_with?('eyJf')

      Rails.logger.info "Found potential signed_id in field '#{key}': #{value[0..20]}..."
      return value
    end

    Rails.logger.info 'Could not find signed_id in parameters, using as-is'
    nil
  end

  def self.process_blob(blob_or_file)
    Rails.logger.info 'Converting blob to signed_id for medical certification attachment'
    Rails.logger.info "BLOB INFO: ID=#{blob_or_file.id}, Key=#{blob_or_file.key}, Content-Type=#{blob_or_file.content_type}, Size=#{blob_or_file.byte_size}"

    signed_id = blob_or_file.signed_id
    Rails.logger.info "Using signed_id: #{signed_id || '[nil]'}"
    signed_id
  end

  def self.process_uploaded_file(blob_or_file)
    log_upload_info(blob_or_file)
    create_blob_from_upload(blob_or_file) || blob_or_file
  end

  def self.log_upload_info(blob_or_file)
    if blob_or_file.respond_to?(:original_filename)
      Rails.logger.info "UPLOAD INFO: Filename=#{blob_or_file.original_filename}, Content-Type=#{blob_or_file.content_type}, Size=#{blob_or_file.size}"
    end
    Rails.logger.info "Using direct file upload attachment: #{blob_or_file.class.name}"
  end

  def self.create_blob_from_upload(blob_or_file)
    Rails.logger.info 'Creating blob from uploaded file'

    blob = ActiveStorage::Blob.create_and_upload!(
      io: blob_or_file.tempfile,
      filename: blob_or_file.original_filename,
      content_type: blob_or_file.content_type
    )

    Rails.logger.info "Successfully created blob for medical_certification: #{blob.id}"
    blob.signed_id
  rescue StandardError => e
    Rails.logger.error "Failed to create blob from uploaded file: #{e.message}"
    Rails.logger.info 'Falling back to direct file parameter'
    nil
  end

  def self.log_fallback_details(blob_or_file)
    Rails.logger.info "ATTACHMENT PARAM TYPE: #{blob_or_file.class.name}"
    begin
      Rails.logger.info "ATTACHMENT PARAM DETAILS: #{blob_or_file.inspect[0..100]}"
    rescue StandardError
      Rails.logger.info 'Could not inspect blob_or_file'
    end
  end

  # Type checking helper methods
  def self.action_controller_parameters?(blob_or_file)
    defined?(ActionController::Parameters) && blob_or_file.is_a?(ActionController::Parameters)
  end

  def self.uploaded_file?(blob_or_file)
    blob_or_file.respond_to?(:tempfile) || blob_or_file.is_a?(ActionDispatch::Http::UploadedFile)
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

  # Attachment processing helper methods
  def self.calculate_blob_size(blob_or_file)
    blob_or_file.byte_size if blob_or_file.respond_to?(:byte_size)
  end

  def self.log_attachment_context(params)
    Rails.logger.info "MEDICAL CERTIFICATION ATTACHMENT INPUT TYPE: #{params[:blob_or_file].class.name}"
    Rails.logger.info "MEDICAL CERTIFICATION ENVIRONMENT: #{Rails.env}"
    Rails.logger.info "MEDICAL CERTIFICATION STORAGE SERVICE: #{ActiveStorage::Blob.service.class.name}"
  end

  def self.perform_attachment(application, attachment_param)
    Rails.logger.info "EXECUTING ATTACHMENT: medical_certification to application #{application.id}"

    fresh_application = Application.unscoped.find(application.id)
    fresh_application.medical_certification.attach(attachment_param)

    # NOTE: attach() returns the attachment object (truthy), not a boolean.
    # Check attached? to verify success.
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
