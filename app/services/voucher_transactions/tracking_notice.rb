# frozen_string_literal: true

module VoucherTransactions
  # A package's first-tracking notice: exactly one per package, sent through NotificationService.
  #
  # The shipment row is the record that a notice is owed: tracking_notification_id stays empty until
  # the notification exists. deliver! locks that row, so concurrent or repeated runs create at most one
  # notification, and a run that fails leaves the notice owed for the sweep to pick up. Corrections and
  # dispatch-date changes never send another. Delivery retries belong to the email and letter pipelines.
  class TrackingNotice
    ACTION = 'shipment_tracking_added'
    # A notice still owed this long after its package was recorded missed its queued run.
    SWEEP_AFTER = 15.minutes

    def self.schedule(shipment_id)
      TrackingNoticeJob.perform_later(shipment_id)
    end

    def self.deliver!(shipment_id)
      ActiveRecord::Base.transaction do
        shipment = VoucherTransactionShipment.lock.find(shipment_id)
        if shipment.tracking_notification_id.nil?
          notification = NotificationService.create_and_deliver!(
            type: ACTION, recipient: recipient_for(shipment), actor: shipment.created_by, notifiable: shipment,
            metadata: { 'voucher_transaction_id' => shipment.voucher_transaction_id }
          )
          shipment.update!(tracking_notification: notification) if notification
        end
        shipment
      end
    end

    def self.sweep!
      VoucherTransactionShipment.awaiting_tracking_notice.where(created_at: ...SWEEP_AFTER.ago)
                                .find_each { |shipment| deliver!(shipment.id) }
    end

    # The application's managing guardian, or the applicant when no one manages it. Chosen here, not
    # by the mailer, so the notice cannot go to a different guardian than the one managing the application.
    def self.recipient_for(shipment)
      application = shipment.voucher_transaction.voucher.application
      application.managing_guardian || application.user
    end
  end
end
