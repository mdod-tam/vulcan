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

  def force_notifications?
    force_notifications.present?
  end

  # Request metadata, set only by Admin::BaseController for audit, template, and mailer readers
  attribute :user_agent, :ip_address
end
