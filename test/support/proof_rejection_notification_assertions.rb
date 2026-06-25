# frozen_string_literal: true

module ProofRejectionNotificationAssertions
  ORPHAN_PROOF_REJECTION_NOTIFICATION_TYPES = %w[
    proof_rejected
    id_proof_rejected
    income_proof_rejected
    residency_proof_rejected
  ].freeze

  def assert_no_orphan_proof_rejection_notification_delivery
    NotificationService.expects(:create_and_deliver!).with do |params|
      ORPHAN_PROOF_REJECTION_NOTIFICATION_TYPES.include?(params[:type].to_s)
    end.never
  end
end
