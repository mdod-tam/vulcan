# frozen_string_literal: true

# Attaches proofs for portal resubmission, paper intake, and secure requests.
# UploadedDocument resolves and validates the file. This service owns proof state, audit, and metrics.
# Attachment and proof state changes share its transaction.
#
# Integration tests must call the real attach_proof method.
# A stub can report success without storing an attachment.
class ProofAttachmentService
  AttachmentEventContext = Struct.new(
    :application, :proof_type, :status, :submission_method,
    :admin, :metadata, :blob_size, :skip_audit_events,
    keyword_init: true # rubocop:disable Style/RedundantStructKeywordInit
  )
  # Attaches a proof document to an application
  #
  # @param args [Hash] A hash containing the arguments for attachment:
  #   - :application [Application] (required) The application to attach the proof to.
  #   - :proof_type [Symbol] (required) The type of proof (:income, :residency, or :id).
  #   - :blob_or_file [ActiveStorage::Blob, String, ActionDispatch::Http::UploadedFile] (required) The file to attach.
  #     A String is a signed blob ID; see UploadedDocument for how each input is resolved and refused.
  #   - :submission_method [Symbol] (required) The method of submission (:paper, :web, :email, etc.).
  #   - :status [Symbol] (optional, default: :not_reviewed) The status to set for the proof.
  #   - :admin [User] (optional) The admin user if this is an admin action.
  #   - :metadata [Hash] (optional) Additional metadata to store with the attachment audit.
  #   - :signed_ids [Boolean] (optional, default: true) Whether a signed blob ID is an accepted input.
  #   - :min_bytes [Integer, nil] (optional) Smallest accepted file, for channels that require one.
  #
  # @return [Hash] Result hash with :success, :error, and :duration_ms keys. A refused upload
  #   leaves :error as an UploadedDocument::Refused and changes no proof state.
  def self.attach_proof(args)
    params = {
      status: :not_reviewed,
      admin: nil,
      metadata: {},
      skip_audit_events: false,
      signed_ids: true,
      min_bytes: nil
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

  # Rejects a proof without a file.
  #
  # @param application [Application] The application to reject the proof for
  # @param proof_type [Symbol] The type of proof (:income, :residency, or :id)
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
      # ProofReview owns `proof_rejected` and delivery through Applications::RequestProofResubmission.
      # An extra `#{proof_type}_proof_rejected` event or notification here would duplicate audit records or delivery.
      result[:success] = perform_rejection(application: application, proof_type: proof_type, admin: admin,
                                           submission_method: submission_method, rejection_details: rejection_details)
    end
  end

  def self.record_failure(error, context)
    log_error(error)
    record_failure_audit_after_transaction(error, context)
  rescue StandardError => e
    Rails.logger.error "Failed to record proof failure: #{e.message}"
  end

  # A caller's rollback would remove an audit event written inside its transaction.
  # Write the event after that transaction ends.
  def self.record_failure_audit_after_transaction(error, context)
    transaction = ApplicationRecord.current_transaction
    return log_failure_audit_event(error, context) unless transaction.open?

    transaction.after_commit { log_failure_audit_event(error, context) }
    transaction.after_rollback { log_failure_audit_event(error, context) }
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
    elsif Rails.env.test? && result[:error]&.message.to_s.match?(/mismatched digest/i)
      Rails.logger.debug do
        "[EXPECTED_TEST_ATTACHMENT] Proof #{proof_type} #{status} failed in #{result[:duration_ms]}ms: #{result[:error]&.message}"
      end
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

  class << self
    private

    def perform_attachment_flow(result, params)
      flow_data = prepare_flow_data(params)

      with_paper_context(flow_data.submission_method, flow_data.proof_type) do |original_paper_context|
        attach_and_verify_initial_save(flow_data.application, flow_data.proof_type, flow_data.attachment_param)
        context, event_metadata = log_attachment_events_from_flow_data(flow_data, params)
        result[:blob_size] = flow_data.blob_size
        result[:success] = true

        # Keep reconciliation in the attachment transaction so attachment and workflow changes remain atomic.
        # A caller with paper context already active owns final reconciliation.
        # Otherwise, reconcile here even when this service temporarily enables paper context.
        if params.fetch(:status).to_sym == :approved && !original_paper_context
          reconcile_if_approved(
            application: flow_data.application,
            admin: params.fetch(:admin),
            proof_type: flow_data.proof_type
          )
        end

        send_notification(context, event_metadata)
      end
    end

    def attach_and_verify_initial_save(application, proof_type, blob)
      application.send(get_attachment_method_name(proof_type)).attach(blob)
      save_application_with_attachment(application)
      verify_attachment_persisted(application, proof_type)
    end

    def get_attachment_method_name(proof_type)
      "#{proof_type}_proof"
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

      attachment_method = get_attachment_method_name(proof_type)
      return if application.send(attachment_method).attached?

      Rails.logger.error "Attachment failed to persist for #{proof_type} proof on application #{application.id}"
      raise 'Attachment failed to persist after save and reload'
    end

    def log_error(error)
      context = Rails.env.test? ? '[TEST_ATTACHMENT] ' : '[ATTACHMENT_ERROR] '
      message = "#{context}Proof attachment error: #{error.message}"

      # Fabricated test files intentionally trigger digest errors.
      # Log those errors at DEBUG to keep test output readable.
      if Rails.env.test? && error.message.to_s.match?(/mismatched digest/i)
        Rails.logger.debug(message)
      else
        Rails.logger.error(message)
      end

      backtrace = error.backtrace&.join("\n")
      Rails.logger.debug(backtrace) if backtrace && Rails.env.test?
      Rails.logger.error(backtrace || 'No backtrace available') unless Rails.env.test?
    end

    # Use a fresh record after the caller's transaction ends.
    # The original object can retain changes from a rollback or refer to a deleted record.
    # Auditing that object could save it and its associations again.
    def log_failure_audit_event(error, context)
      application = Application.find_by(id: context.fetch(:application).id)
      return unless application

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
      return submission_method.to_sym if submission_method.present?

      method = application.submission_method.presence
      method ? method.to_sym : SubmissionMethodValidator.validate(submission_method)
    end

    def with_service_flow(context)
      start_time = Time.current
      result = { success: false, error: nil, duration_ms: 0 }

      begin
        ApplicationRecord.transaction do
          yield(result)
        end
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

    def log_attachment_events(context)
      event_metadata = build_event_metadata(context)

      log_audit_event(context, event_metadata) unless context.skip_audit_events
      update_application_status(context)

      event_metadata
    end

    def build_event_metadata(context)
      attachment_method = get_attachment_method_name(context.proof_type)
      attached_blob = context.application.send(attachment_method).blob
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
      action_suffix = context.submission_method.to_s == 'email' ? 'submitted' : 'attached'

      AuditEventService.log(
        action: "#{context.proof_type}_proof_#{action_suffix}",
        auditable: context.application,
        actor: context.admin || context.application.user,
        metadata: event_metadata
      )
    end

    def update_application_status(context)
      attrs = { "#{context.proof_type}_proof_status" => context.status }
      attrs[:needs_review_since] = Time.current if context.status == :not_reviewed

      context.application.update!(attrs)
      context.application.reload
    end

    def reconcile_if_approved(application:, admin:, proof_type:)
      actor = admin || Current.user || application.user
      application.reconcile_workflow_state!(
        actor: actor,
        trigger: :"#{proof_type}_proof_approved"
      )
    rescue StandardError => e
      Rails.logger.error "Workflow reconciliation failed for Application #{application.id}: #{e.message}\n#{e.backtrace.join("\n")}"
    end

    def send_notification(context, event_metadata)
      # PaperApplicationService owns notifications while paper context is active.
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

      resolved = RejectionReason.resolve_for_persistence(
        code: raw_reason,
        proof_type: proof_type.to_s,
        fallback: raw_reason,
        interpolations: {
          address: [
            application.user&.physical_address_1,
            application.user&.physical_address_2,
            [application.user&.city, application.user&.state, application.user&.zip_code].compact.join(' ')
          ].compact_blank.join(' ').squish
        }
      )
      reason_text = resolved[:text]
      reason_code = resolved[:code]

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

    # Resolves the file before proof state changes. Refusal raises at this boundary.
    def prepare_flow_data(params)
      application = params.fetch(:application)
      proof_type = params.fetch(:proof_type)
      blob = UploadedDocument.resolve!(
        params.fetch(:blob_or_file),
        record: application,
        name: get_attachment_method_name(proof_type),
        signed_ids: params.fetch(:signed_ids),
        min_bytes: params.fetch(:min_bytes)
      )

      Struct.new(:application, :proof_type, :attachment_param, :blob_size, :submission_method, keyword_init: true).new( # rubocop:disable Style/RedundantStructKeywordInit
        application: application,
        proof_type: proof_type,
        attachment_param: blob,
        blob_size: blob.byte_size,
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

      [context, log_attachment_events(context)]
    end

    def with_paper_context(submission_method, _proof_type)
      original_paper_context = Current.paper_context
      begin
        Current.paper_context = true if submission_method.to_sym == :paper
        yield(original_paper_context)
      ensure
        Current.paper_context = original_paper_context
      end
    end
  end
end
