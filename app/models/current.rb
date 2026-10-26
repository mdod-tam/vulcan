# frozen_string_literal: true

# Request-scoped state. Rails resets these attributes at the start and end of every request and job.
class Current < ActiveSupport::CurrentAttributes
  # Set while an admin paper application is processed. Several proof validations are skipped in this context.
  attribute :paper_context

  # Skips the proof validations. Set by services that manage proof state themselves, and by tests.
  attribute :skip_proof_validation

  # The signed-in user.
  attribute :user

  attribute :request_id

  attribute :force_notifications

  # Set during a single-proof admin review. The reviewer validates the selected proof, so the all-proofs checks are skipped.
  attribute :reviewing_single_proof

  # Test environment only: the authentication concern signs this user in.
  attribute :test_user_id

  # Set by ProofAttachmentService so ProofManageable does not record a second event for the same attachment.
  attribute :proof_attachment_service_context

  def paper_context?
    paper_context.present?
  end

  def skip_proof_validation?
    skip_proof_validation.present?
  end

  def reviewing_single_proof?
    reviewing_single_proof.present?
  end

  def force_notifications?
    force_notifications.present?
  end

  def proof_attachment_service_context?
    proof_attachment_service_context.present?
  end

  # Request metadata, set only by Admin::BaseController for audit, template, and mailer readers
  attribute :user_agent, :ip_address
end
