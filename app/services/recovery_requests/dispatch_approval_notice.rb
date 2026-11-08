# frozen_string_literal: true

module RecoveryRequests
  # Reuses the captured envelope so concurrent retries cannot duplicate transport.
  class DispatchApprovalNotice
    def initialize(recovery_request, refresh_failed_context: false)
      @request = recovery_request
      @refresh_failed_context = refresh_failed_context
    end

    def call
      notification = @request.reload_approval_notification
      return :not_available unless @request.approved? && notification

      context = prepare(notification)
      return :already_submitted unless context

      delivered = EmailDelivery::NotificationDispatch.new(notification, channel: :email, context: context).call
      delivered ? :queued : :failed
    rescue StandardError => e
      Rails.logger.error("Recovery notice dispatch failed for request #{@request.id}: #{e.class.name}")
      record_failure(notification, e)
      :failed
    end

    private

    def record_failure(notification, error)
      notification&.mark_delivery_failed!(error, channel: :email)
    rescue StandardError => e
      Rails.logger.error("Recovery notice failure could not be recorded for request #{@request.id}: #{e.class.name}")
    end

    def prepare(notification)
      context = nil
      notification.with_lock do
        attempts = notification.email_delivery_attempts.to_a
        next if notification.delivery_status.in?(%w[submitted delivered opened]) || attempts.any? { |attempt| !attempt.retryable? }

        context = notification.metadata['recovery_delivery_context']
        context = nil if @refresh_failed_context && attempts.empty? && notification.local_delivery_outcome?
        context ||= EmailDelivery::Policy.capture(mail_action: 'ApplicationNotificationsMailer#security_key_recovery_approved',
                                                  params: { notification_id: notification.id })
        notification.update!(delivery_status: nil,
                             metadata: notification.metadata.except('delivery_error', 'delivery_suppressed').merge(
                               'recovery_delivery_context' => context
                             ))
      end
      context
    end
  end
end
