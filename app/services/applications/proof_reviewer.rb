# frozen_string_literal: true

module Applications
  class ProofReviewer
    attr_reader :proof_review

    def initialize(application, admin)
      @application = application
      @admin = admin
    end

    # Set when the review committed but a later step failed.
    def warning = @commit&.warning

    def review(proof_type:, status:, rejection_reason: nil, rejection_reason_code: nil, notes: nil)
      Rails.logger.debug { "Starting review with proof_type: #{proof_type.inspect}, status: #{status.inspect}" }

      @proof_type_key = proof_type.to_s
      @status_key = status.to_s
      @proof_review = nil
      @lifecycle_history_ids = []
      @lifecycle_audit_ids = []
      @commit = ReviewCommit.new(application: @application, subject: 'proof review', again: 'reviewing it again') { durable_state }

      Rails.logger.debug { "Converted values - proof_type: #{@proof_type_key.inspect}, status: #{@status_key.inspect}" }

      @commit.run(on_committed: ->(error) { @proof_review.log_follow_up_failure(error) }) do
        @commit.transaction do
          create_or_update_proof_review(rejection_reason, rejection_reason_code, notes)
          update_application_status
          purge_if_rejected
          reconcile_if_approved
        end

        follow_up_on_decision
      end

      true
    end

    private

    # The facts one review writes. ReviewCommit compares them before the writes, after them, and after an error.
    # The review row is the one the review finds or creates, so a rolled-back new row reads as absent.
    def durable_state
      review = if @proof_review&.id
                 ProofReview.find_by(id: @proof_review.id)
               else
                 @application.proof_reviews.find_by(proof_type: @proof_type_key, status: @status_key)
               end
      {
        review: review&.attributes_for_database,
        application: Application.where(id: @application.id).pick(:status, "#{@proof_type_key}_proof_status", :total_rejections),
        lifecycle: [ApplicationStatusChange.where(id: @lifecycle_history_ids).count, Event.where(id: @lifecycle_audit_ids).count]
      }
    end

    def reconcile_if_approved
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
        application: @application
      )
      @proof_review = ProofReview.for_decision(@application, proof_type: @proof_type_key, status: @status_key)

      assign = {
        admin: @admin,
        notes: notes
      }
      if @status_key == 'rejected'
        assign[:rejection_reason_code] = rejection_reason_code
        assign[:rejection_reason] = rejection_reason_text
      else
        # Only a rejected review carries a reason.
        assign[:rejection_reason_code] = nil
        assign[:rejection_reason] = nil
      end

      apply_submission_method_from_latest_submission_event
      @proof_review.record!(**assign)

      Rails.logger.debug do
        "Saved ProofReview ID: #{@proof_review.id}, status: #{@proof_review.status}, " \
          "proof_type: #{@proof_review.proof_type}, new_record: #{@proof_review.previously_new_record?}"
      end
    end

    # A new decision and a repeat rejection alike follow up once the transaction that recorded them, and any
    # transaction around it, has committed.
    def follow_up_on_decision
      ActiveRecord.after_all_transactions_commit { ProofDecisionFollowUp.new(@proof_review).call }
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

    def update_application_status
      Rails.logger.debug { "Updating application status for proof_type: #{@proof_type_key}, status: #{@status_key}" }

      validate_proof_attachment_if_approved
      update_proof_status_column
      @application.reload
    end

    def validate_proof_attachment_if_approved
      return unless @status_key == 'approved'

      attachment = @application.send("#{@proof_type_key}_proof")
      return DocumentScan.require_clean!(attachment.blob) if attachment.attached?

      raise ActiveRecord::RecordInvalid.new(@application),
            "#{@proof_type_key.capitalize} proof must be attached to approve"
    end

    def update_proof_status_column
      column_name = "#{@proof_type_key}_proof_status"
      @application.update!(column_name => @status_key)
    end

    def purge_if_rejected
      return unless @status_key == 'rejected'

      Rails.logger.debug { "[ProofReviewer] Status is rejected for #{@proof_type_key}, attempting purge." }
      @application.purge_rejected_proof(@proof_type_key)
    end
  end
end
