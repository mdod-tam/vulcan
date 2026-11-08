# frozen_string_literal: true

class ContactChangeDeliveryJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  def perform(request_id, role)
    change = ContactChangeRequest.find(request_id)
    return if change.delivery_states[role].in?(ContactChangeRequest::FINAL_DELIVERY_STATES)
    return unless ContactChangeRequest::DELIVERY_ROLES.include?(role)
    return if ContactChangeRequest::EMAIL_PROOFS.include?(role) && !change.pending?

    context = change.delivery_contexts.fetch(role)
    if (state = recorded_submission_state(context))
      change.set_delivery_state!(role, state)
      return
    end

    mailer = ContactChangeMailer.with(contact_change_request: change, role: role, user: change.user)
    delivery = ContactChangeRequest::EMAIL_PROOFS.include?(role) ? mailer.verification : mailer.security_notice
    change.set_delivery_state!(role, deliver_submission_state(delivery, context))
  rescue ApplicationMailer::DeliverySkipped
    change&.set_delivery_state!(role, 'suppressed')
  rescue StandardError => e
    change&.set_delivery_state!(role, 'error')
    Rails.logger.warn("Contact notice delivery failed: #{e.class.name}")
    raise
  end

  private

  def deliver_submission_state(delivery, context)
    message = EmailDelivery.deliver_now!(delivery, context: context)
    submission_state(message, context)
  rescue EmailDelivery::NotAccepted
    recorded_submission_state(context) || raise
  end

  def recorded_submission_state(context)
    attempts = EmailDeliveryAttempt.where(correlation_id: EmailDeliveryAttempt.correlation_for(context)).to_a
    return unless attempts.any? && attempts.any? { |attempt| !attempt.retryable? }

    attempts.all? { |attempt| attempt.accepted_at || attempt.provider_message_id.present? || attempt.feedback_at } ? 'submitted' : 'unknown'
  end

  def submission_state(message, context)
    recorded = recorded_submission_state(context)
    return recorded if recorded

    message.delivery_method.is_a?(Mail::Postmark) ? 'unknown' : 'submitted'
  end
end
