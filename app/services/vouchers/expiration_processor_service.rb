# frozen_string_literal: true

module Vouchers
  # Records expiry and its notice together, then dispatches notices independently of voucher status.
  class ExpirationProcessorService < BaseService
    WARNING_ACTION = 'expiration_warning_requested'
    WARNING_HISTORY = [WARNING_ACTION, 'expiration_warning_sent'].freeze
    def call
      deliver_pending_expiration_notices
      process_expiring_soon_vouchers
      process_expired_vouchers
      deliver_pending_expiration_notices

      success('Voucher expiration processing completed')
    rescue StandardError => e
      log_error(e, 'Failed to process voucher expirations')
      failure('Failed to process voucher expirations')
    end

    private

    # The warning window spans several daily runs, so a voucher is warned once; its event is the
    # record of that. Without a system audit account the warning cannot be recorded, so it is not sent.
    def process_expiring_soon_vouchers
      return unless (actor = PublicAuditActor.system_audit_actor_or_report('voucher expiration warning'))

      vouchers_expiring_soon.find_each do |voucher|
        next if voucher.events.exists?(action: WARNING_HISTORY)

        context = EmailDelivery::Policy.capture(mail_action: 'VoucherNotificationsMailer#voucher_expiring_soon')
        outcome = EmailDelivery.deliver_later(VoucherNotificationsMailer.with(voucher: voucher).voucher_expiring_soon, context: context)
        # Operational failures remain retryable on the next run; intentional suppression is terminal.
        next if %i[enqueue_failed configuration_error].include?(outcome)

        AuditEventService.log(
          actor: actor,
          auditable: voucher,
          action: WARNING_ACTION,
          metadata: { days_until_expiry: 7, expiration_date: voucher.expiration_date,
                      delivery_outcome: outcome, delivery_request_id: context['request_id'] }
        )
      end
    end

    def process_expired_vouchers
      actor = PublicAuditActor.system_audit_actor_or_report('voucher expiration')
      raise 'Voucher expiration requires the configured system audit actor' unless actor

      expired_vouchers.find_each do |voucher|
        voucher.with_lock do
          next unless voucher.voucher_active? && voucher.expired?

          voucher.update!(status: :expired)
          AuditEventService.log(
            actor: actor, auditable: voucher, action: 'expired',
            metadata: { expiration_date: voucher.expiration_date, remaining_value: voucher.remaining_value }
          )
          notification = NotificationService.create_and_deliver!(
            type: 'voucher_expired', recipient: voucher.application.user, actor: actor,
            notifiable: voucher, channel: :email, deliver: false
          )
          context = EmailDelivery::Policy.capture(mail_action: 'VoucherNotificationsMailer#voucher_expired',
                                                  params: { notification_id: notification.id })
          notification.update_metadata!('expiration_delivery_context', context)
        end
      end
    end

    # A failed queue write leaves the intent here even though its voucher is already expired.
    # Reusing the capture preserves suppression and the provider/letter replay identity.
    def deliver_pending_expiration_notices
      Notification.where(action: 'voucher_expired', notifiable_type: 'Voucher', delivery_status: [nil, 'error']).find_each do |notification|
        notification.with_lock do
          next unless expiration_notice_retryable?(notification)

          context = notification.metadata.fetch('expiration_delivery_context')
          if notification.error_delivery_status?
            notification.update!(delivery_status: nil,
                                 metadata: notification.metadata.except('delivery_error', 'actual_delivery_channel', 'delivery_route_reason'))
          end
          EmailDelivery::NotificationDispatch.new(notification, channel: :email, context: context).call
        end
      end
    end

    def expiration_notice_retryable?(notification)
      return false if notification.email_delivery_attempts.exists?
      return true if notification.delivery_status.nil?

      notification.error_delivery_status? && notification.metadata['delivery_route_reason'] == 'email_enqueue_failed'
    end

    def vouchers_expiring_soon
      active_vouchers.where(
        "issued_at + (INTERVAL '1 month' * ?) - CURRENT_TIMESTAMP BETWEEN INTERVAL '6 days' AND INTERVAL '8 days'",
        voucher_validity_period
      )
    end

    def expired_vouchers
      active_vouchers.where(
        "issued_at + (INTERVAL '1 month' * ?) < CURRENT_TIMESTAMP",
        voucher_validity_period
      )
    end

    def active_vouchers
      Voucher.where(status: :active)
    end

    def voucher_validity_period
      @voucher_validity_period ||= Policy.get('voucher_validity_period_months')
    end
  end
end
