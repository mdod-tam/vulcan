# frozen_string_literal: true

module Applications
  class ProofReviewer
    class CommitUnconfirmed < StandardError; end

    attr_reader :proof_review, :warning

    def initialize(application, admin)
      @application = application
      @admin = admin
    end

    def review(proof_type:, status:, rejection_reason: nil, rejection_reason_code: nil, notes: nil)
      @warning = nil
      @expected_review_attributes = nil
      Rails.logger.debug { "Starting review with proof_type: #{proof_type.inspect}, status: #{status.inspect}" }

      @proof_type_key = proof_type.to_s
      @status_key = status.to_s

      Rails.logger.debug { "Converted values - proof_type: #{@proof_type_key.inspect}, status: #{@status_key.inspect}" }

      with_single_proof_review_context do
        ApplicationRecord.transaction do
          @previous_application_state = @application.attributes_for_database.slice('status', "#{@proof_type_key}_proof_status")
          create_or_update_proof_review(rejection_reason, rejection_reason_code, notes)
          update_application_status
          purge_if_rejected
          reconcile_if_approved
          @expected_review_attributes = @proof_review.attributes_for_database
          @expected_application_state = @application.attributes_for_database.slice('status', "#{@proof_type_key}_proof_status")
        end
      end

      process_re_rejection_side_effects

      true
    rescue StandardError => e
      Rails.logger.error "Proof review failed: #{e.message}"
      Rails.logger.error e.backtrace&.join("\n")

      case review_commit_state
      when :committed
        @warning = 'The proof review was saved, but a follow-up step did not finish. Check this application before reviewing it again.'
        record_incomplete_follow_up(e)
        true
      when :unknown
        raise CommitUnconfirmed, 'The proof review may have been saved, but that could not be confirmed. Check this application before reviewing it again.'
      else
        raise
      end
    end

    private

    # Match this operation's review and application writes, not merely an existing row.
    def review_commit_state
      return :rolled_back unless @expected_review_attributes

      stored_review = ProofReview.find_by(id: @proof_review.id)
      return :rolled_back if stored_review.nil? && @previous_review_attributes['id'].nil?
      return :unknown unless stored_review

      stored_attributes = stored_review.attributes_for_database
      if stored_attributes == @expected_review_attributes
        return :unknown if @expected_review_attributes == @previous_review_attributes &&
                           @expected_application_state == @previous_application_state

        return :committed if application_writes_present?
      elsif stored_attributes == @previous_review_attributes
        return :rolled_back
      end

      :unknown
    rescue StandardError => e
      Rails.logger.error "Could not confirm proof review commit for Application #{@application.id}: #{e.class.name}"
      :unknown
    end

    def application_writes_present?
      application_state = Application.find(@application.id).attributes_for_database.slice(*@expected_application_state.keys)
      return false unless application_state == @expected_application_state
      return true if @expected_application_state['status'] == @previous_application_state['status']

      @lifecycle_history_ids.any? &&
        ApplicationStatusChange.where(id: @lifecycle_history_ids).count == @lifecycle_history_ids.size &&
        @lifecycle_audit_ids.any? && Event.where(id: @lifecycle_audit_ids).count == @lifecycle_audit_ids.size
    end

    def record_incomplete_follow_up(error)
      AuditEventService.log(
        action: 'proof_review_follow_up_failed',
        actor: @admin,
        auditable: @application,
        metadata: { proof_review_id: @proof_review.id, proof_type: @proof_type_key, error_class: error.class.name }
      )
    rescue StandardError => e
      Rails.logger.error "Could not record proof review follow-up failure for Application #{@application.id}: #{e.class.name}"
    end

    def reconcile_if_approved
      @lifecycle_history_ids = []
      @lifecycle_audit_ids = []
      return unless @status_key == 'approved'

      @application.reload
      previous_status = @application.status
      history_id = @application.status_changes.maximum(:id).to_i
      audit_id = @application.events.where(action: 'application_status_changed').maximum(:id).to_i
      @application.reconcile_workflow_state!(actor: @admin, trigger: :proof_review_approved)
      return if @application.status == previous_status

      @lifecycle_history_ids = @application.status_changes.where('id > ?', history_id).ids
      @lifecycle_audit_ids = @application.events.where(action: 'application_status_changed').where('id > ?', audit_id).ids
    end

    def create_or_update_proof_review(rejection_reason, rejection_reason_code, notes)
      Rails.logger.debug 'Finding or initializing proof review record'

      rejection_reason_text = RejectionReason.resolve_text(
        code: rejection_reason_code,
        proof_type: @proof_type_key,
        fallback: rejection_reason,
        interpolations: rejection_reason_interpolations
      )
      find_attributes      = build_find_attributes
      @proof_review        = @application.proof_reviews.find_or_initialize_by(find_attributes)
      @previous_review_attributes = @proof_review.attributes_for_database

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
      apply_submission_method_from_latest_submission_event
      set_reviewed_at_if_needed
      @proof_review.save!

      Rails.logger.debug do
        "Saved ProofReview ID: #{@proof_review.id}, status: #{@proof_review.status}, " \
          "proof_type: #{@proof_review.proof_type}, new_record: #{@proof_review.previously_new_record?}"
      end
    end

    def process_re_rejection_side_effects
      return unless repeat_rejection?

      @proof_review.apply_repeat_rejection_side_effects!
    end

    def repeat_rejection?
      return false if @proof_review.previously_new_record?
      return false unless @status_key == 'rejected'

      true
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

    def apply_submission_method_from_latest_submission_event
      submission_method = latest_submission_method_from_event
      return if submission_method.blank?
      return unless ProofReview.submission_methods.key?(submission_method)

      @proof_review.submission_method = submission_method
    end

    def latest_submission_method_from_event
      event = @application.latest_proof_submission_event(@proof_type_key)
      event&.metadata&.fetch('submission_method', nil).presence ||
        event&.metadata&.fetch(:submission_method, nil).presence
    end

    def rejection_reason_interpolations
      { address: application_address_text }
    end

    def application_address_text
      [
        @application.user&.physical_address_1,
        @application.user&.physical_address_2,
        [@application.user&.city, @application.user&.state, @application.user&.zip_code].compact.join(' ')
      ].compact_blank.join(' ').squish
    end

    def update_application_status
      Rails.logger.debug { "Updating application status for proof_type: #{@proof_type_key}, status: #{@status_key}" }

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

      Rails.logger.debug { "[ProofReviewer] Status is rejected for #{@proof_type_key}, attempting purge." }
      # Call a method on the application model to handle the purge
      @application.purge_rejected_proof(@proof_type_key)
    end

    def with_single_proof_review_context
      previous_value = Current.reviewing_single_proof
      Current.reviewing_single_proof = true
      yield
    ensure
      Current.reviewing_single_proof = previous_value
    end
  end
end
