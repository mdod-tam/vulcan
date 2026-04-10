# frozen_string_literal: true

module Applications
  class ProofReviewer
    def initialize(application, admin)
      @application = application
      @admin = admin
    end

    def review(proof_type:, status:, rejection_reason: nil, rejection_reason_code: nil, notes: nil)
      Rails.logger.info "Starting review with proof_type: #{proof_type.inspect}, status: #{status.inspect}"

      @proof_type_key = proof_type.to_s
      @status_key = status.to_s

      Rails.logger.info "Converted values - proof_type: #{@proof_type_key.inspect}, status: #{@status_key.inspect}"

      ApplicationRecord.transaction do
        create_or_update_proof_review(rejection_reason, rejection_reason_code, notes)
        update_application_status
        purge_if_rejected
      end

      true
    rescue StandardError => e
      Rails.logger.error "Proof review failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise
    end

    private

    def create_or_update_proof_review(rejection_reason, rejection_reason_code, notes)
      Rails.logger.info 'Finding or initializing proof review record'

      rejection_reason_text = RejectionReason.resolve_text(
        code: rejection_reason_code,
        proof_type: @proof_type_key,
        fallback: rejection_reason
      )
      find_attributes      = build_find_attributes
      @proof_review        = @application.proof_reviews.find_or_initialize_by(find_attributes)

      assign = {
        admin: @admin,
        notes: notes
      }
      if @status_key == 'rejected'
        assign[:rejection_reason_code] = rejection_reason_code
        assign[:rejection_reason] = rejection_reason_text
      else
        # Preserve data integrity for non-rejected reviews.
        assign[:rejection_reason_code] = nil
        assign[:rejection_reason] = nil
      end

      @proof_review.assign_attributes(assign)
      set_reviewed_at_if_needed
      @proof_review.save!

      Rails.logger.info "Saved ProofReview ID: #{@proof_review.id}, status: #{@proof_review.status},
      proof_type: #{@proof_review.proof_type}, new_record: #{@proof_review.previously_new_record?}"
    end

    def build_find_attributes
      { proof_type: @proof_type_key, status: @status_key }
    end

    def set_reviewed_at_if_needed
      # If it's an existing record being updated, the `on: :create` `set_reviewed_at` callback
      # won't run. We need to explicitly update `reviewed_at` to reflect this new review action.
      # If it's a new record, the `on: :create` callback will set it.
      # `reviewed_at` is validated for presence, so it must be set before save!.
      @proof_review.reviewed_at = Time.current unless @proof_review.new_record?
    end

    def update_application_status
      Rails.logger.info "Updating application status for proof_type: #{@proof_type_key}, status: #{@status_key}"

      validate_proof_attachment_if_approved
      update_proof_status_column
      @application.reload
    end

    def validate_proof_attachment_if_approved
      return unless @status_key == 'approved'

      attachment = @application.send("#{@proof_type_key}_proof")
      return if attachment.attached?

      raise ActiveRecord::RecordInvalid.new(@application),
            "#{@proof_type_key.capitalize} proof must be attached to approve"
    end

    def update_proof_status_column
      column_name = "#{@proof_type_key}_proof_status"
      @application.update!(column_name => @status_key)
    end

    # Explicitly call purge logic on the application if the status was just set to rejected
    def purge_if_rejected
      return unless @status_key == 'rejected'

      Rails.logger.info "[ProofReviewer] Status is rejected for #{@proof_type_key}, attempting purge."
      # Call a method on the application model to handle the purge
      @application.purge_rejected_proof(@proof_type_key)
    end
  end
end
