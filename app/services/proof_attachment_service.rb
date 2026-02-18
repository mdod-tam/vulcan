# frozen_string_literal: true

# Service to handle proof attachments with consistent transaction handling and telemetry
#
# This service is the central point for all proof attachment operations in the application.
# It's used by both the constituent portal and paper application workflows to ensure
# consistency in how attachments are processed, validated, and tracked.
#
# Key responsibilities:
# 1. Provide a unified interface for attaching proofs for both paper and online submissions
# 2. Handle blob/file conversion for different input types
# 3. Maintain audit records and metrics for all attachment operations
# 4. Provide consistent error handling and diagnostics
#
# This is the single source of truth for attachment operations to avoid inconsistencies
# between different submission paths.
#
# IMPORTANT FOR TESTING: Do NOT stub ProofAttachmentService.attach_proof in integration tests
# This method performs the actual file attachment logic. Stubbing it will cause tests to
# report success but no actual attachments will be created, leading to false positives.
# Use real test data and let the service run normally for proper integration testing.
class ProofAttachmentService
  # Parameter object for attachment event logging to reduce method parameter count
  AttachmentEventContext = Struct.new(
    :application, :proof_type, :status, :submission_method,
    :admin, :metadata, :blob_size, :skip_audit_events,
    keyword_init: true
  )
  # Attaches a proof document to an application
  #
  # This is the central method used by both constituent portal and paper application
  # workflows to attach proof documents. It handles different input types, manages
  # transactions, and provides consistent logging and metrics.
  #
  # @param args [Hash] A hash containing the arguments for attachment:
  #   - :application [Application] (required) The application to attach the proof to.
  #   - :proof_type [Symbol] (required) The type of proof (:income or :residency).
  #   - :blob_or_file [ActiveStorage::Blob, String, ActionDispatch::Http::UploadedFile] (required) The file to attach.
  #   - :submission_method [Symbol] (required) The method of submission (:paper, :web, :email, etc.).
  #   - :status [Symbol] (optional, default: :not_reviewed) The status to set for the proof.
  #   - :admin [User] (optional) The admin user if this is an admin action.
  #   - :metadata [Hash] (optional) Additional metadata to store with the attachment audit.
  #
  # @return [Hash] Result hash with :success, :error, and :duration_ms keys
  def self.attach_proof(args)
    params = {
      status: :not_reviewed,
      admin: nil,
      metadata: {},
      skip_audit_events: false
    }.merge(args)

    context = {
      application: params.fetch(:application),
      proof_type: params.fetch(:proof_type),
      admin: params.fetch(:admin),
      submission_method: params.fetch(:submission_method),
      metadata: params.fetch(:metadata),
      status: params.fetch(:status)
    }

    original_service_context = Current.proof_attachment_service_context
    Current.proof_attachment_service_context = true

    begin
      with_service_flow(context) do |result|
        perform_attachment_flow(result, params)
      end
    ensure
      Current.proof_attachment_service_context = original_service_context
    end
  end

  # Rejects a proof without requiring a file attachment
  #
  # This method is used to explicitly reject proof submissions, typically when an admin
  # is reviewing a paper application and decides not to accept the proof document.
  # It maintains the same audit trail and metrics as the attachment flow.
  #
  # @param application [Application] The application to reject the proof for
  # @param proof_type [Symbol] The type of proof (:income or :residency)
  # @param admin [User] The admin user performing the rejection (required)
  # @param submission_method [Symbol] The method of submission (:paper, :web, :email, etc.)
  # @param rejection_details [Hash] Details about the rejection, including:
  #   - :reason [String] The reason for rejection (e.g., 'unclear', 'incomplete', 'other')
  #   - :notes [String, nil] Optional notes explaining the rejection
  #   - :metadata [Hash] Additional metadata to store with the rejection audit
  #
  # @return [Hash] Result hash with :success, :error, and :duration_ms keys
  def self.reject_proof_without_attachment(application:, proof_type:, admin:, submission_method:, **rejection_details)
    context = {
      application: application, proof_type: proof_type, admin: admin,
      submission_method: submission_method, metadata: rejection_details.fetch(:metadata, {}),
      status: :rejected
    }

    with_service_flow(context) do |result|
      success = perform_rejection(application: application, proof_type: proof_type, admin: admin,
                                  submission_method: submission_method, rejection_details: rejection_details)

      if success
        log_rejection_events(application: application, proof_type: proof_type, admin: admin,
                             submission_method: submission_method, rejection_details: rejection_details)
      end

      result[:success] = success
    end
  end

  def self.record_failure(error, context)
    log_error(error)
    log_failure_audit_event(error, context)
  rescue StandardError => e
    Rails.logger.error "Failed to record proof failure: #{e.message}"
  end

  def self.record_metrics(result, proof_type, status)
    record_basic_logging(result, proof_type, status)
    context = build_context(result, proof_type, status)
    record_datadog_metrics(result, context, proof_type, status)
  rescue StandardError => e
    Rails.logger.error "Failed to record proof metrics: #{e.message}"
  end

  def self.record_basic_logging(result, proof_type, status)
    if result[:success]
      Rails.logger.info "Proof #{proof_type} #{status} completed in #{result[:duration_ms]}ms"
    else
      Rails.logger.error "Proof #{proof_type} #{status} failed in #{result[:duration_ms]}ms: #{result[:error]&.message}"
    end
  end

  def self.build_context(result, proof_type, status)
    context = build_base_context(result, proof_type, status)
    add_blob_size_to_context(context, result)
    add_error_details_to_context(context, result)
    context
  end

  def self.build_base_context(result, proof_type, status)
    {
      proof_type: proof_type,
      status: status,
      success: result[:success],
      duration_ms: result[:duration_ms],
      environment: Rails.env,
      transaction_id: SecureRandom.uuid
    }
  end

  def self.add_blob_size_to_context(context, result)
    return unless result[:success] && result[:blob_size].present?

    context[:blob_size_bytes] = result[:blob_size]
  end

  def self.add_error_details_to_context(context, result)
    return unless result[:error]

    context[:error_class] = result[:error].class.name
    context[:error_message] = result[:error].message
    context[:error_backtrace] = result[:error].backtrace.first(3) if result[:error].backtrace
  end

  def self.record_datadog_metrics(result, _context, proof_type, status)
    return unless defined?(Datadog)

    tags = [
      "proof_type:#{proof_type}",
      "status:#{status}",
      "success:#{result[:success]}",
      "environment:#{Rails.env}"
    ]
    Datadog.increment('proof_attachments.operations', tags: tags)
    Datadog.timing('proof_attachments.duration', result[:duration_ms], tags: tags)
    return unless result[:success] && result[:blob_size].present?

    Datadog.histogram('proof_attachments.size', result[:blob_size], tags: tags)
  end

  # private class methods
  class << self
    private

    def perform_attachment_flow(result, params)
      flow_data = prepare_flow_data(params)

      with_paper_context(flow_data.submission_method, flow_data.proof_type) do
        attach_and_verify_initial_save(flow_data.application, flow_data.proof_type, flow_data.attachment_param)
        log_attachment_events_from_flow_data(flow_data, params)
        # Removed verify_attachment_persisted_after_update - status updates don't affect attachments

        result[:blob_size] = flow_data.blob_size
        result[:success] = true
      end
    end

    def attach_and_verify_initial_save(application, proof_type, attachment_param)
      perform_attachment(application, proof_type, attachment_param)
      save_application_with_attachment(application)
      verify_attachment_persisted(application, proof_type)
    end

    def perform_attachment(application, proof_type, attachment_param)
      application.send("#{proof_type}_proof").attach(attachment_param)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound => e
      handle_attachment_signature_error(application, proof_type, attachment_param, e)
    end

    def handle_attachment_signature_error(application, proof_type, attachment_param, error)
      Rails.logger.warn "ActiveStorage signed ID error: #{error.message}. Attempting to recreate blob."

      validate_recoverable_attachment_param(attachment_param, error)
      blob = recreate_blob_from_uploaded_file(attachment_param)
      application.send("#{proof_type}_proof").attach(blob)
    end

    def validate_recoverable_attachment_param(attachment_param, error)
      if attachment_param.is_a?(String) && attachment_param.start_with?('eyJf')
        Rails.logger.error "Invalid signed ID detected, cannot recover. Original error: #{error.message}"
        raise 'Failed to attach proof: Invalid or expired attachment reference'
      end

      return if attachment_param.respond_to?(:tempfile) || attachment_param.is_a?(ActionDispatch::Http::UploadedFile)

      raise "Failed to attach proof: #{error.message}"
    end

    def recreate_blob_from_uploaded_file(attachment_param)
      ActiveStorage::Blob.create_and_upload!(
        io: attachment_param.tempfile,
        filename: attachment_param.original_filename,
        content_type: attachment_param.content_type
      )
    rescue StandardError => e
      Rails.logger.error "Failed to recreate blob: #{e.message}"
      raise "Failed to attach proof after retry: #{e.message}"
    end

    def save_application_with_attachment(application)
      application.save!
    rescue StandardError => e
      Rails.logger.error "Save failed: #{e.message}"
      log_validation_errors(application) unless Rails.env.test? && ENV['VERBOSE_TESTS'].blank?
      raise "Failed to save application with attachment: #{e.message}"
    end

    def log_validation_errors(application)
      Rails.logger.error "Validation errors: #{application.errors.full_messages.join(', ')}"
    end

    def verify_attachment_persisted(application, proof_type)
      application.reload

      return if application.send("#{proof_type}_proof").attached?

      Rails.logger.error "Attachment failed to persist for #{proof_type} proof on application #{application.id}"
      raise 'Attachment failed to persist after save and reload'
    end

    def log_error(error)
      context = Rails.env.test? ? '[TEST_ATTACHMENT] ' : '[ATTACHMENT_ERROR] '
      message = "#{context}Proof attachment error: #{error.message}"

      # In the test environment we intentionally trigger mismatched-digest errors with
      # fabricated files.  Logging them at ERROR level creates noisy output without
      # adding signal, so downgrade to DEBUG when we detect that scenario.
      if Rails.env.test? && error.message.to_s.match?(/mismatched digest/i)
        Rails.logger.debug(message)
      else
        Rails.logger.error(message)
      end

      backtrace = error.backtrace&.join("\n")
      Rails.logger.debug(backtrace) if backtrace && Rails.env.test?
      Rails.logger.error(backtrace || 'No backtrace available') unless Rails.env.test?
    end

    def log_failure_audit_event(error, context)
      application = context.fetch(:application)
      proof_type = context.fetch(:proof_type)

      result_for_context = { success: false, error: error }
      audit_metadata = build_context(result_for_context, proof_type, :attachment_failed)

      safe_submission_method = determine_submission_method(application, context.fetch(:submission_method))
      audit_metadata[:submission_method] = safe_submission_method

      final_metadata = context.fetch(:metadata).merge(audit_metadata)

      AuditEventService.log(
        action: "#{proof_type}_proof_attachment_failed",
        auditable: application,
        actor: context.fetch(:admin) || application.user,
        metadata: final_metadata
      )
    rescue StandardError => e
      Rails.logger.error "Failed to record audit for failure: #{e.message}"
    end

    def determine_submission_method(application, submission_method)
      method = application.submission_method.presence || submission_method.presence
      method ? method.to_sym : SubmissionMethodValidator.validate(submission_method)
    end

    def with_service_flow(context)
      start_time = Time.current
      result = { success: false, error: nil, duration_ms: 0 }

      begin
        yield(result)
      rescue StandardError => e
        result[:success] = false
        result[:error] = e
        record_failure(e, context)
      ensure
        result[:duration_ms] = ((Time.current - start_time) * 1000).round
        record_metrics(result, context.fetch(:proof_type), context.fetch(:status))
      end

      result
    end

    def calculate_blob_size(blob_or_file)
      return blob_or_file.byte_size if blob_or_file.respond_to?(:byte_size)
      return blob_or_file.size if blob_or_file.respond_to?(:size)

      0
    end

    def prepare_attachment_param(blob_or_file, _proof_type)
      return blob_or_file if blob_or_file.is_a?(ActiveStorage::Blob)
      return blob_or_file if blob_or_file.is_a?(String) && blob_or_file.start_with?('eyJf')

      if blob_or_file.respond_to?(:tempfile) || blob_or_file.is_a?(ActionDispatch::Http::UploadedFile)
        begin
          blob = ActiveStorage::Blob.create_and_upload!(
            io: blob_or_file.tempfile,
            filename: blob_or_file.original_filename,
            content_type: blob_or_file.content_type
          )
          return blob.signed_id
        rescue StandardError => e
          Rails.logger.error "Failed to create blob from uploaded file: #{e.message}"
        end
      end

      blob_or_file
    end

    def log_attachment_events(context)
      event_metadata = build_event_metadata(context)

      log_audit_event(context, event_metadata) unless context.skip_audit_events
      update_application_status(context)
      send_notification(context, event_metadata)
    end

    def build_event_metadata(context)
      attached_blob = context.application.send("#{context.proof_type}_proof").blob
      blob_id = attached_blob&.id

      context.metadata.merge(
        proof_type: context.proof_type,
        submission_method: context.submission_method,
        status: context.status,
        has_attachment: true,
        blob_id: blob_id,
        blob_size: context.blob_size,
        success: true,
        filename: attached_blob&.filename.to_s
      )
    end

    def log_audit_event(context, event_metadata)
      # Use 'submitted' for email submissions, 'attached' for other submissions
      action_suffix = context.submission_method.to_s == 'email' ? 'submitted' : 'attached'

      AuditEventService.log(
        action: "#{context.proof_type}_proof_#{action_suffix}",
        auditable: context.application,
        actor: context.admin || context.application.user,
        metadata: event_metadata
      )
    end

    def update_application_status(context)
      ActiveRecord::Base.transaction do
        status_attrs = { "#{context.proof_type}_proof_status" => context.status }
        status_attrs[:needs_review_since] = Time.current if context.status == :not_reviewed
        context.application.update!(status_attrs)
      end
    end

    def send_notification(context, event_metadata)
      # Skip notifications if this is a paper application as paper applications handle their own notifications in PaperApplicationService
      return if Current.paper_context

      NotificationService.create_and_deliver!(
        type: "#{context.proof_type}_proof_attached",
        recipient: context.application.user,
        actor: context.admin || context.application.user,
        notifiable: context.application,
        metadata: event_metadata
      )
    end

    def perform_rejection(application:, proof_type:, admin:, submission_method:, rejection_details:)
      raw_reason = rejection_details.fetch(:reason, 'other')
      notes      = rejection_details.fetch(:notes, nil)

      # When the caller supplies a known RejectionReason code (e.g. from a
      # select dropdown), persist the code and look up the human-readable body.
      # Fall back to the raw value for free-text / "other" reasons.
      rr = RejectionReason.resolve(code: raw_reason, proof_type: proof_type.to_s)
      reason_code = rr ? raw_reason : nil
      reason_text = rr&.body || raw_reason

      with_paper_context(submission_method, proof_type) do
        application.reject_proof_without_attachment!(
          proof_type,
          admin: admin,
          reason: reason_text,
          notes: notes || 'Rejected during paper application submission'
        )

        application.proof_reviews.create!(
          admin: admin,
          proof_type: proof_type,
          status: 'rejected',
          rejection_reason: reason_text,
          rejection_reason_code: reason_code,
          notes: notes,
          reviewed_at: Time.current,
          submission_method: submission_method
        )
      end
    end

    def log_rejection_events(application:, proof_type:, admin:, submission_method:, rejection_details:)
      reason = rejection_details.fetch(:reason, 'other')
      metadata = rejection_details.fetch(:metadata, {})
      audit_metadata = metadata.merge(
        proof_type: proof_type,
        submission_method: submission_method,
        status: :rejected,
        has_attachment: false,
        rejection_reason: reason
      )

      AuditEventService.log(
        action: "#{proof_type}_proof_rejected",
        auditable: application,
        actor: admin,
        metadata: audit_metadata
      )

      # Skip notifications if this is a paper application context as PaperApplicationService handles notifications
      return if Current.paper_context

      NotificationService.create_and_deliver!(
        type: "#{proof_type}_proof_rejected",
        recipient: application.user,
        actor: admin,
        notifiable: application,
        metadata: audit_metadata
      )
    end

    def prepare_flow_data(params)
      blob_or_file = params.fetch(:blob_or_file)

      Struct.new(:application, :proof_type, :attachment_param, :blob_size, :submission_method, keyword_init: true).new(
        application: params.fetch(:application),
        proof_type: params.fetch(:proof_type),
        attachment_param: prepare_attachment_param(blob_or_file, params.fetch(:proof_type)),
        blob_size: calculate_blob_size(blob_or_file),
        submission_method: params.fetch(:submission_method)
      )
    end

    def log_attachment_events_from_flow_data(flow_data, params)
      context = AttachmentEventContext.new(
        application: flow_data.application,
        proof_type: flow_data.proof_type,
        status: params.fetch(:status),
        submission_method: flow_data.submission_method,
        admin: params.fetch(:admin),
        metadata: params.fetch(:metadata),
        blob_size: flow_data.blob_size,
        skip_audit_events: params.fetch(:skip_audit_events)
      )

      log_attachment_events(context)
    end

    def with_paper_context(submission_method, _proof_type)
      original_paper_context = Current.paper_context
      begin
        Current.paper_context = true if submission_method.to_sym == :paper
        yield
      ensure
        Current.paper_context = original_paper_context
      end
    end
  end
end
