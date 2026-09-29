# frozen_string_literal: true

module Vouchers
  # Warns constituents before a voucher expires and expires vouchers past their validity period.
  # The expired notice belongs to Voucher#check_status_changes, which runs for every path to expired.
  class ExpirationProcessorService < BaseService
    WARNING_ACTION = 'expiration_warning_requested'
    WARNING_HISTORY = [WARNING_ACTION, 'expiration_warning_sent'].freeze
    def call
      process_expiring_soon_vouchers
      process_expired_vouchers

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

        voucher.events.create!(
          user: actor,
          action: WARNING_ACTION,
          metadata: { days_until_expiry: 7, expiration_date: voucher.expiration_date,
                      delivery_outcome: outcome, delivery_request_id: context['request_id'] }
        )
      end
    end

    def process_expired_vouchers
      expired_vouchers.find_each do |voucher|
        voucher.update!(status: :expired)
        next unless (actor = PublicAuditActor.system_audit_actor_or_report('voucher expired event'))

        voucher.events.create!(
          user: actor,
          action: 'expired',
          metadata: { expiration_date: voucher.expiration_date, remaining_value: voucher.remaining_value }
        )
      end
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
