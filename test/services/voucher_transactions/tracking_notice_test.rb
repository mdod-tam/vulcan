# frozen_string_literal: true

require 'test_helper'

module VoucherTransactions
  class TrackingNoticeTest < ActiveJob::TestCase
    setup do
      load_seeded_email_templates('voucher_notifications_shipment_tracking_added')
      ActionMailer::Base.deliveries.clear
      @vendor = create(:vendor, :approved, business_name: 'Accessible Phones Co')
    end

    test 'a managed application notifies its managing guardian, not the first guardian or the dependent' do
      first_guardian = create(:constituent, email: "first-guardian-#{SecureRandom.hex(3)}@example.com")
      manager = create(:constituent, email: "manager-#{SecureRandom.hex(3)}@example.com")
      dependent = create(:constituent, email: "dependent-#{SecureRandom.hex(3)}@example.com")
      create(:guardian_relationship, guardian_user: first_guardian, dependent_user: dependent)
      create(:guardian_relationship, guardian_user: manager, dependent_user: dependent)
      application = create(:application, user: dependent, managing_guardian: manager)
      assert_equal first_guardian, dependent.reload.guardian_for_contact, 'precondition: the first guardian differs from the manager'

      shipment = record_package(purchase_for(application), 'AAA111')
      notification = shipment.reload.tracking_notification

      assert_equal manager, notification.recipient
      assert_equal [[manager.email]], ActionMailer::Base.deliveries.map(&:to)
    end

    test 'an unmanaged application notifies the applicant, with the vendor, package, and order link' do
      application = create(:application)

      shipment = record_package(purchase_for(application), '1Z 999 AA1')

      mail = ActionMailer::Base.deliveries.sole
      body = mail.text_part&.decoded || mail.body.decoded
      assert_equal [application.user.email], mail.to
      assert_equal 'A package from Accessible Phones Co is on its way', mail.subject
      assert_includes body, '1Z 999 AA1'
      assert_includes body, "/constituent_portal/applications/#{application.id}#orders-and-shipping"
      assert_equal application.user, shipment.reload.tracking_notification.recipient
    end

    test 'repeat runs, the sweep, and corrections send no second notice' do
      shipment = record_package(purchase_for(create(:application)), 'AAA111')
      notification = shipment.reload.tracking_notification

      travel 1.hour do
        perform_enqueued_jobs do
          TrackingNotice.deliver!(shipment.id)
          TrackingNoticeJob.perform_now
          service_for(shipment.voucher_transaction).correct_shipment!(
            shipment_id: shipment.id, attributes: { 'tracking_number' => 'AAA112' }, expected_lock_version: shipment.lock_version
          )
        end
      end

      assert_equal notification, shipment.reload.tracking_notification
      assert_equal 1, Notification.where(action: TrackingNotice::ACTION, notifiable: shipment).count
      assert_equal 1, ActionMailer::Base.deliveries.size
    end

    test 'a notice whose queued run never happened is sent by the sweep once it is overdue' do
      purchase = purchase_for(create(:application))
      shipment = service_for(purchase).add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)
      clear_enqueued_jobs # The commit happened but the queued run was lost.

      perform_enqueued_jobs { TrackingNoticeJob.perform_now }
      assert_nil shipment.reload.tracking_notification_id, 'a package recorded moments ago is left for its own queued run'

      travel TrackingNotice::SWEEP_AFTER + 1.minute do
        perform_enqueued_jobs { TrackingNoticeJob.perform_now }
      end
      assert shipment.reload.tracking_notification_id
      assert_equal 1, ActionMailer::Base.deliveries.size
    end

    test 'a failed notice leaves the package owed so the next run can send it' do
      purchase = purchase_for(create(:application))
      NotificationService.stubs(:create_and_deliver!).returns(nil)
      shipment = record_package(purchase, 'AAA111')
      assert_includes VoucherTransactionShipment.awaiting_tracking_notice, shipment

      NotificationService.unstub(:create_and_deliver!)
      perform_enqueued_jobs { TrackingNotice.deliver!(shipment.id) }
      assert shipment.reload.tracking_notification_id
    end

    test 'a letter-preferring recipient gets one letter, even when the delivery is retried' do
      application = create(:application)
      application.user.update!(communication_preference: :letter)
      shipment = service_for(purchase_for(application)).add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)

      perform_enqueued_jobs(only: TrackingNoticeJob)
      mail_jobs = enqueued_jobs.dup
      assert mail_jobs.any?, 'the notice should queue its delivery'
      2.times { mail_jobs.each { |job| ActiveJob::Base.execute(job.stringify_keys) } }
      TrackingNotice.deliver!(shipment.id)

      assert_equal 1, PrintQueueItem.where(constituent: application.user, application: application).count
      assert_empty ActionMailer::Base.deliveries
    end

    private

    def purchase_for(application)
      voucher = create(:voucher, :active, application: application, vendor: @vendor)
      create(:voucher_transaction, voucher: voucher, vendor: @vendor, amount: 100)
    end

    def service_for(purchase)
      FulfillmentService.new(transaction: purchase, actor: @vendor)
    end

    def record_package(purchase, tracking_number)
      perform_enqueued_jobs do
        service_for(purchase).add_shipment!(attributes: { 'tracking_number' => tracking_number },
                                            expected_version: purchase.reload.fulfillment_version)
      end
    end
  end
end
