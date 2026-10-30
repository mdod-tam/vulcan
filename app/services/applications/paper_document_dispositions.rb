# frozen_string_literal: true

module Applications
  # Applies paper document choices through the canonical attachment and review writers.
  class PaperDocumentDispositions
    def initialize(params:, admin:, application:, errors:, warnings:)
      @params = params
      @admin = admin
      @application = application
      @errors = errors
      @warnings = warnings
    end

    def call
      proof_types = %i[income residency id disability_certification]
      proof_types -= %i[income] unless @application.income_proof_required?

      proof_types.each do |proof_type|
        return false unless process_proof(proof_type)
      end

      true
    end

    private

    attr_reader :params

    def process_proof(type)
      action_key = "#{DocumentType.fetch(type).attachment_name}_action"
      action = params[action_key] || params[action_key.to_sym]

      return true unless %w[upload_only accept reject approved rejected not_requested].include?(action)

      case action
      when 'upload_only'
        process_upload_only_proof(type)
      when 'accept', 'approved'
        process_accept_proof(type)
      when 'reject', 'rejected'
        process_reject_proof(type)
      when 'not_requested'
        true
      end
    end

    def process_upload_only_proof(type)
      upload = submitted_document(type)
      return add_error("Please upload a file for #{proof_upload_label(type)} before sending it for review") if upload.blank?

      attach_document(type, upload, status: type == :disability_certification ? :received : :not_reviewed)
    end

    def proof_upload_label(type)
      type == :disability_certification ? 'disability certification' : "#{type} proof"
    end

    def process_accept_proof(type)
      upload = submitted_document(type)
      return add_error("Please upload a file for #{type} proof before approving") if upload.blank?

      attach_document(type, upload, status: :approved)
    end

    def submitted_document(type)
      UploadedDocument.submitted(params, DocumentType.fetch(type).attachment_name.to_s)
    end

    def attach_document(type, upload, status:)
      result = if type == :disability_certification
                 DisabilityCertificationAttachmentService.attach_certification(
                   application: @application, blob_or_file: upload, status: status,
                   admin: @admin, submission_method: :paper, metadata: {}
                 )
               else
                 ProofAttachmentService.attach_proof(
                   application: @application, proof_type: type, blob_or_file: upload, status: status,
                   admin: @admin, submission_method: :paper, metadata: {}
                 )
               end
      return true if result[:success]

      add_error("Error processing #{proof_upload_label(type)}: #{result[:error]&.message}")
    rescue UploadedDocument::Refused => e
      add_error(e.user_message_for(proof_upload_label(type).upcase_first))
    rescue DisabilityCertificationAttachmentService::StaffUploadNotAllowed => e
      add_error("#{proof_upload_label(type).upcase_first}: #{e.message}")
    end

    def process_reject_proof(type)
      field = DocumentType.fetch(type).attachment_name
      selected_reason = fetch_param("#{field}_rejection_reason").to_s
      custom_reason = fetch_param("#{field}_custom_rejection_reason").to_s.strip
      legacy_notes = fetch_param("#{field}_rejection_notes").to_s.strip
      custom_reason = legacy_notes if custom_reason.blank? && legacy_notes.present?

      result = if type == :disability_certification
                 reject_disability_certification(
                   selected_reason: selected_reason,
                   custom_reason: custom_reason,
                   notes: legacy_notes.presence
                 )
               else
                 reject_non_certification_proof(
                   type: type,
                   selected_reason: selected_reason,
                   custom_reason: custom_reason,
                   notes: legacy_notes.presence
                 )
               end

      unless result[:success]
        add_error("Error rejecting #{type} proof: #{result[:error]&.message}")
        return false
      end

      true
    end

    def resolve_rejection_reason_value(selected_reason:, custom_reason:)
      return selected_reason unless selected_reason == 'other'
      return 'Other' if custom_reason.blank?

      custom_reason
    end

    def reject_non_certification_proof(type:, selected_reason:, custom_reason:, notes:)
      resolved_reason = resolve_rejection_reason_value(
        selected_reason: selected_reason,
        custom_reason: custom_reason
      )

      ProofAttachmentService.reject_proof_without_attachment(
        application: @application,
        proof_type: type,
        admin: @admin,
        reason: resolved_reason,
        notes: notes,
        submission_method: :paper,
        metadata: {}
      )
    end

    def resolve_disability_certification_rejection_reason_payload(selected_reason:, custom_reason:)
      return { reason: custom_reason.presence || 'Other', reason_code: nil } if selected_reason.blank? || selected_reason == 'other'

      reason = RejectionReason.resolve_text(
        code: selected_reason, proof_type: 'disability_certification', fallback: selected_reason, application: @application
      )
      { reason: reason, reason_code: selected_reason }
    end

    def fetch_param(key)
      params[key] || params[key.to_sym]
    end

    def reject_disability_certification(selected_reason:, custom_reason:, notes:)
      reason_payload = resolve_disability_certification_rejection_reason_payload(
        selected_reason: selected_reason, custom_reason: custom_reason
      )
      if selected_reason == 'none_provided' || !certifying_professional_notification_available?
        return DisabilityCertificationAttachmentService.reject_certification(
          application: @application, admin: @admin, reason: reason_payload[:reason], notes: notes,
          reason_code: reason_payload[:reason_code], submission_method: :paper, metadata: {}
        )
      end

      reviewer_result = Applications::DisabilityCertificationReviewer.new(@application, @admin).reject(
        rejection_reason: reason_payload[:reason],
        notes: notes,
        rejection_reason_code: reason_payload[:reason_code]
      )

      if reviewer_result.success?
        ActiveRecord.after_all_transactions_commit do
          delivery = reviewer_result.data.fetch(:provider_delivery)
          upload_request_failed = reviewer_result.data[:secure_upload_request]&.dig(:success) == false
          if !delivery[:success] || delivery[:tracking_status] == :failed || upload_request_failed || reviewer_result.data[:warnings].present?
            add_warning(reviewer_result.message)
          end
        end
        return { success: true, provider_delivery: reviewer_result.data[:provider_delivery] }
      end

      { success: false, error: StandardError.new(reviewer_result.message) }
    end

    def certifying_professional_notification_available?
      @application.certifying_professional_name.present? &&
        (@application.certifying_professional_email.present? || @application.certifying_professional_fax.present?)
    end

    def add_error(message)
      @errors << message
      false
    end

    def add_warning(message)
      @warnings << message unless @warnings.include?(message)
    end
  end
end
