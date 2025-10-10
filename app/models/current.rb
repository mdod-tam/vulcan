# frozen_string_literal: true

# Current attributes for request-scoped state management
# Replaces Thread-local variables with Rails' built-in CurrentAttributes pattern
# This ensures proper state isolation across requests and better testability
class Current < ActiveSupport::CurrentAttributes
  # Paper application context - used to bypass certain validations during admin paper application processing
  attribute :paper_context

  # Proof resubmission context - used to bypass validations during proof resubmission flows
  attribute :resubmitting_proof

  # Skip proof validation flag - used in tests and specific service contexts
  attribute :skip_proof_validation

  # Current user for request context
  attribute :user

  # Request ID for tracking and debugging
  attribute :request_id

  # Force notifications flag for testing scenarios
  attribute :force_notifications

  # Single proof review flag for targeted review operations
  attribute :reviewing_single_proof

  # Test user ID for testing scenarios (replaces Thread.current[:test_user_id])
  attribute :test_user_id

  # ProofAttachmentService context - used to prevent duplicate events from ProofManageable concern
  attribute :proof_attachment_service_context

  # Convenience methods for boolean checks

  def paper_context?
    paper_context.present?
  end

  def resubmitting_proof?
    resubmitting_proof.present?
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

  # Reset callback to ensure clean state between requests
  resets do
    # Log state reset in development for debugging - only when attributes are actually set
    if Rails.env.development? && (paper_context.present? || resubmitting_proof.present?)
      Rails.logger.debug { "Current attributes reset: paper_context=#{paper_context}, resubmitting_proof=#{resubmitting_proof}" }
    end
  end

  # Legacy attributes that were already in the class
  attribute :user_agent, :ip_address

  class << self
    def set(request, user)
      self.user_agent = request.user_agent
      self.ip_address = request.remote_ip
      self.user = user
    end
  end
end
