# frozen_string_literal: true

# Request-scoped state. Rails resets these attributes at the start and end of every request and job.
class Current < ActiveSupport::CurrentAttributes
  # Set while an admin paper application is processed. It relaxes the contact requirements on a user, and tells
  # ProofAttachmentService that the paper intake owns workflow reconciliation and delivery. It does not change
  # whether a proof validation runs.
  attribute :paper_context

  # The signed-in user.
  attribute :user

  attribute :request_id

  attribute :force_notifications

  # Test environment only: the authentication concern signs this user in.
  attribute :test_user_id

  # Set by ProofAttachmentService so ProofManageable does not stamp needs_review_since a second time for an
  # attachment the service already handled.
  attribute :proof_attachment_service_context

  def force_notifications?
    force_notifications.present?
  end

  def proof_attachment_service_context?
    proof_attachment_service_context.present?
  end

  # Request metadata, set only by Admin::BaseController for audit, template, and mailer readers
  attribute :user_agent, :ip_address
end
