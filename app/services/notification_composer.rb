# frozen_string_literal: true

# Composes user-facing messages for notifications.
# This service decouples message content from the Notification model and decorator,
# providing a single source of truth for all notification text. This makes
# testing, maintenance, and future localization much simpler.
#
# Usage:
#   NotificationComposer.generate(
#     notification.action,
#     notification.notifiable,
#     notification.actor,
#     notification.metadata
#   )
#
class NotificationComposer
  include ActionView::Helpers::TextHelper # For helpers like pluralize

  def self.generate(notification_action, notifiable, actor = nil, metadata = {})
    new(notification_action, notifiable, actor, metadata).generate
  end

  def initialize(action, notifiable, actor, metadata)
    @action = action.to_s
    @notifiable = notifiable
    @actor = actor
    @metadata = metadata || {}
  end

  def generate
    method_name = "message_for_#{@action}"
    if respond_to?(method_name, true)
      send(method_name)
    else
      default_message
    end
  end

  private

  # --- Message Generation Methods ---

  def message_for_trainer_assigned
    trainer_name = @actor&.full_name || 'A trainer'
    application = @notifiable
    constituent_name = application.try(:constituent_full_name) || 'a constituent'

    training_session = find_training_session(application, @actor)
    status_info = training_session ? " (#{training_session.status.humanize})" : ''

    "#{trainer_name} assigned to train #{constituent_name} for Application ##{@notifiable&.id}#{status_info}."
  end

  def message_for_proof_rejected
    proof_type = @metadata['proof_type']&.titleize || 'Proof'
    reason = @metadata['rejection_reason']
    reason_text = reason.present? ? " - #{reason}" : ''

    "#{proof_type} rejected for application ##{@notifiable&.id}#{reason_text}."
  end

  def message_for_proof_approved
    proof_type = @metadata['proof_type']&.titleize || 'Proof'
    "#{proof_type} approved for application ##{@notifiable&.id}."
  end

  def message_for_medical_certification_requested
    "Disability certification requested for application ##{@notifiable&.id}"
  end

  def message_for_medical_certification_received
    "Disability certification received for application ##{@notifiable&.id}"
  end

  def message_for_medical_certification_approved
    "Disability certification approved for application ##{@notifiable&.id}"
  end

  def message_for_medical_certification_rejected
    reason = @metadata['reason']
    reason_text = reason.present? ? " - #{reason}" : ''
    "Disability certification rejected for application ##{@notifiable&.id}#{reason_text}."
  end

  def message_for_documents_requested
    "Documents requested for application ##{@notifiable&.id}"
  end

  def message_for_review_requested
    "Review requested for application ##{@notifiable&.id}"
  end

  def default_message
    "#{@action.humanize} notification regarding #{@notifiable.class.name} ##{@notifiable&.id}."
  end

  # --- Helper Methods ---

  def find_training_session(application, actor)
    return nil unless application.respond_to?(:training_sessions) && actor

    application.training_sessions.where(trainer_id: actor.id).order(:created_at).last
  end
end
