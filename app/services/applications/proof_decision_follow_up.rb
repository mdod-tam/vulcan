# frozen_string_literal: true

module Applications
  # What a recorded income, residency, or ID decision sets in motion once it has committed: the rejection-limit
  # notices, then either the rejection audit with a secure resubmission request or the approval record.
  #
  # The writers that record a decision schedule this after their transaction commits, for every decision they record:
  # a new one, a repeat rejection, and a repeat approval, such as a proof approved again after a replacement.
  # A disability certification rejection has its own follow-up in DisabilityCertificationReviewer, so a certification
  # review must never be scheduled here.
  class ProofDecisionFollowUp
    # @raise [ArgumentError] when the review is not an income, residency, or ID review
    def initialize(review)
      unless ProofReview.reviewable_proof_type?(review.proof_type)
        raise ArgumentError, "#{review.proof_type.inspect} reviews have their own follow-up, not ProofDecisionFollowUp"
      end

      @review = review
    end

    def call
      notify_rejection_limit
      # Skip when the applicant or the admin record is missing.
      return unless application&.user.present? && admin.present?

      review.status_rejected? ? request_resubmission : record_approval
    rescue StandardError => e
      Rails.logger.error "Failed to process proof review #{review.id} actions for application #{review.application_id}: #{e.class.name}"
      raise
    end

    private

    attr_reader :review

    delegate :application, :admin, to: :review

    # Sent after the commit. A failure here must not fail a review that has committed.
    def notify_rejection_limit
      total = review.rejection_total
      return unless total

      send_max_rejections_warning if total >= ProofReview::MAX_REJECTIONS
      ApplicationNotificationsMailer.max_rejections_reached(application).deliver_later if total > ProofReview::MAX_REJECTIONS
    rescue StandardError => e
      Rails.logger.error "Failed to send rejection limit notices for ProofReview #{review.id}: #{e.class.name}"
    end

    def send_max_rejections_warning
      # Each rejection at the limit records a staff warning. Its operation id keeps distinct
      # decisions while the canonical audit window suppresses a retry of the same decision.
      AuditEventService.log(
        action: 'max_rejections_warning',
        actor: admin,
        auditable: application,
        metadata: { recipient_id: admin.id, operation_id: operation_id('max_rejections_warning') }
      )

      NotificationService.create_and_deliver!(
        type: 'max_rejections_warning',
        recipient: admin,
        actor: admin,
        notifiable: application,
        channel: :email,
        deliver: false
      )
    end

    def request_resubmission
      log_rejection_audit_event
      issue_resubmission_form
    end

    def issue_resubmission_form
      # An application archived by this rejection is sent the archive notice, not an upload link it could not use.
      return if application.status_archived?

      result = RequestProofResubmission.new(
        application: application,
        actor: admin,
        proof_type: review.proof_type.to_sym
      ).call
      return unless result.failure?

      Rails.logger.warn("Proof resubmission request failed for ProofReview #{review.id}: #{result.message}")
      log_resubmission_request_failure(result.message, delivery_suppressed: result.data.is_a?(Hash) && result.data[:delivery_suppressed])
    rescue StandardError => e
      Rails.logger.error "Failed to request proof resubmission for ProofReview #{review.id}: #{e.class.name}"
      log_resubmission_request_failure(e.class.name)
    end

    # The rejection stands when its secure link cannot be sent. This audit event lets staff follow up.
    # This method does not try a different recipient.
    # delivery_suppressed means that the email controls stopped the email on purpose. It is not a delivery failure.
    def log_resubmission_request_failure(reason, delivery_suppressed: false)
      AuditEventService.log(
        action: 'proof_resubmission_request_failed',
        actor: admin,
        auditable: application,
        metadata: { proof_type: review.proof_type, proof_review_id: review.id, reason: reason.to_s,
                    delivery_suppressed: delivery_suppressed.presence }.compact
      )
    rescue StandardError => e
      Rails.logger.error "Failed to record proof resubmission request failure for ProofReview #{review.id}: #{e.class.name}"
    end

    # Each decision has its own operation id. Without one, the audit dedup window keeps only the first event of an
    # action for an application, so two proofs decided within it would lose the second event, such as rejecting two
    # proofs in one intake. A repeat decision stamps a new reviewed_at, so it keeps its own event too.
    def operation_id(outcome)
      "proof-review-#{review.id}-#{outcome}-#{review.reviewed_at.utc.iso8601(6)}"
    end

    def log_rejection_audit_event
      AuditEventService.log(
        action: 'proof_rejected',
        actor: admin,
        auditable: application,
        metadata: {
          proof_type: review.proof_type,
          rejection_reason: review.rejection_reason,
          submission_method: review.submission_method,
          rejection_reason_code: review.rejection_reason_code,
          operation_id: operation_id('rejected')
        }.compact
      )
    end

    # Records a notification for Recent Notifications, but sends no email or letter.
    # Constituents see the proof status in the portal. Staff see the audit event.
    def record_approval
      AuditEventService.log(
        action: 'proof_approved',
        actor: admin,
        auditable: application,
        metadata: { proof_type: review.proof_type, operation_id: operation_id('approved') }
      )

      # Queries filter on notifiable_type: 'Application', so the notifiable must be the application.
      NotificationService.create_and_deliver!(
        type: 'proof_approved',
        recipient: approval_recipient,
        actor: admin,
        notifiable: application,
        metadata: { proof_type: review.proof_type },
        channel: :email,
        deliver: false
      )
    rescue StandardError => e
      Rails.logger.error "Failed to send proof_approved notification for ProofReview #{review.id} via NotificationService: #{e.class.name}"
      # A notification error must not fail the review.
    end

    def approval_recipient
      resolver = SecureRequestRecipientResolver.new(application: application)
      default_recipient_id = resolver.default_recipient_ids.first

      resolver.known_recipients.find { |recipient| recipient.id == default_recipient_id } || application.user
    end
  end
end
