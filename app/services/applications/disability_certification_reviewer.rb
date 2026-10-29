# frozen_string_literal: true

module Applications
  # Rejects certifications and requests a corrected document from the provider.
  class DisabilityCertificationReviewer < BaseService
    attr_reader :application, :admin

    def initialize(application, admin)
      super()
      @application = application
      @admin = admin
    end

    # Records the rejection and attempts provider notification. When the rejection commits but a later step
    # fails, the result succeeds with a warning and the provider is not contacted. When the database cannot
    # confirm the commit, the result fails with data[:commit_state] set to :unknown. Under a caller's open
    # transaction (paper intake) the caller owns the commit, and an error propagates.
    # @param rejection_reason [String] The reason for rejection
    # @param notes [String, nil] Optional additional notes for internal use
    # @param rejection_reason_code [String, nil] Stable code for locale-aware resolution (e.g. missing_signature)
    # @return [BaseService::Result] Result object with success status and any error messages
    def reject(rejection_reason:, notes: nil, rejection_reason_code: nil)
      Rails.logger.info "Rejecting disability certification for Application ##{application.id}"

      validation_result = validate_rejection_inputs(rejection_reason)
      return validation_result if validation_result.failure?

      commit = review_commit
      service_result = commit.run(on_committed: ->(error) { rejection_review&.log_follow_up_failure(error) }) do
        commit.transaction { reject_certification(rejection_reason, notes, rejection_reason_code) }
      end
      # A nil result means the rejection committed and a later step failed.
      return failure(service_result[:error]&.message || 'Disability certification service failed') if service_result && !service_result[:success]

      note_result = create_rejection_note(notes)
      warnings = note_result.failure? ? [note_result.message] : []
      return rejection_saved_with_warning(commit.warning, warnings) if service_result.nil?

      warnings << 'Rejection notification tracking is unavailable; verify provider email before retrying.' if service_result[:notification_id].nil?
      result = success(nil, { notification_id: service_result[:notification_id],
                              provider_delivery: { success: false, outcome: :deferred }, warnings: warnings })
      result.message = rejection_message(result.data)

      # Paper intake may own an outer transaction. Rollback discards this provider attempt.
      ActiveRecord.after_all_transactions_commit do
        request_result = request_secure_certification_upload
        result.data[:secure_upload_request] = { success: request_result.success?, message: request_result.message }
        result.data[:provider_delivery].replace(
          notify_certifying_professional(
            rejection_reason, service_result[:notification_id],
            secure_upload_url: request_result.data&.dig(:secure_upload_url)
          )
        )
        result.message = rejection_message(result.data)
      end
      result
    rescue ReviewCommit::Unconfirmed => e
      failure(e.message, { commit_state: :unknown })
    end

    private

    def review_commit
      ReviewCommit.new(application: application, subject: 'certification rejection', again: 'rejecting it again') { durable_state }
    end

    # The facts a certification rejection writes. ReviewCommit compares them before the writes, after them, and
    # after an error.
    def durable_state
      {
        certification: Application.where(id: application.id).pick(
          :disability_certification_status, :disability_certification_verified_at, :disability_certification_verified_by_id
        ),
        review: rejection_review&.attributes_for_database,
        history: ApplicationStatusChange.where(application_id: application.id, change_type: 'disability_certification').count
      }
    end

    def rejection_review
      application.proof_reviews.find_by(proof_type: :disability_certification, status: :rejected)
    end

    # The provider is not contacted, because the saved state is not fully known.
    def rejection_saved_with_warning(warning, warnings)
      data = { notification_id: nil, provider_delivery: { success: false, outcome: :failed }, warnings: [*warnings, warning] }
      result = success(nil, data)
      result.message = rejection_message(data)
      result
    end

    def validate_rejection_inputs(rejection_reason)
      return failure('Rejection reason is required') if rejection_reason.blank?
      return failure('Admin user is required') if admin.blank?

      success
    end

    def reject_certification(rejection_reason, notes, rejection_reason_code)
      DisabilityCertificationAttachmentService.reject_certification(
        application: application,
        admin: admin,
        reason: rejection_reason,
        notes: notes,
        reason_code: rejection_reason_code
      )
    end

    def request_secure_certification_upload
      result = Applications::RequestCertificationUpload.new(
        application: application,
        actor: admin,
        deliver_email: false
      ).call

      return result if result.success?

      Rails.logger.warn(
        "Secure cert upload form not sent for rejected certification on application #{application.id}"
      )
      result
    rescue StandardError => e
      Rails.logger.warn(
        "Secure cert upload form not sent for rejected certification on application #{application.id}: #{e.class.name}"
      )
      failure('Secure upload link could not be created')
    end

    def notify_certifying_professional(rejection_reason, notification_id, secure_upload_url: nil)
      CertifyingProfessionalNotifier.new(application).send_certification_rejection_notice(
        rejection_reason: rejection_reason,
        admin: admin,
        notification_id: notification_id,
        secure_upload_url: secure_upload_url
      )
    rescue StandardError => e
      Rails.logger.error("Provider notification failed for application #{application.id}: #{e.class.name}")
      { success: false, outcome: :failed, error: e.class.name, tracking_status: :failed }
    end

    def rejection_message(data)
      delivery = data.fetch(:provider_delivery)
      message = case delivery[:outcome]
                when :submitted then 'Provider email submitted.'
                when :queued then 'Provider email queued.'
                when :deferred then 'Provider notification will be attempted after the application is saved.'
                when :suppressed then 'Provider email was not sent because delivery is disabled. Contact the provider manually.'
                else 'Provider email was not sent. Contact the provider manually.'
                end
      warnings = data.fetch(:warnings).dup
      warnings << 'Delivery tracking failed; verify provider email before retrying.' if delivery[:tracking_status] == :failed
      warnings << 'A secure upload link could not be created.' if data[:secure_upload_request] && !data[:secure_upload_request][:success]
      ['Disability certification rejected.', message, *warnings].join(' ')
    end

    def create_rejection_note(notes)
      return success if notes.blank?

      begin
        ApplicationNote.transaction(requires_new: true) do
          application.application_notes.create!(
            admin: admin,
            content: "Disability certification rejected: #{notes}"
          )
        end
        success
      rescue StandardError => e
        Rails.logger.error("Failed to create application note: #{e.class.name}")
        failure('The rejection note could not be saved. Review the notes manually.')
      end
    end
  end
end
