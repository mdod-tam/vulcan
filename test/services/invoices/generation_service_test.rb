# frozen_string_literal: true

require 'test_helper'

module Invoices
  class GenerationServiceTest < ActiveJob::TestCase
    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @vendor = create(:vendor)
      @transactions = [
        create(:voucher_transaction, vendor: @vendor, amount: 100, processed_at: 2.days.ago),
        create(:voucher_transaction, vendor: @vendor, amount: 150.25, processed_at: 1.day.ago)
      ]
      load_seeded_email_templates('vendor_notifications_invoice_generated')
      ActionMailer::Base.deliveries.clear
    end

    # Transactions record what was spent at the time. A voucher redeemed since then has a lower
    # balance, which must not make its earlier transactions invalid when they are invoiced.
    test 'transactions from a partly and then fully redeemed voucher are invoiced' do
      Policy.stubs(:voucher_minimum_redemption_amount).returns(10)
      voucher = create(:voucher, initial_value: 100, remaining_value: 100, vendor: nil)
      first = voucher.redeem!(65, @vendor)
      second = voucher.redeem!(35, @vendor)
      assert first && second, 'both redemptions should succeed'
      assert voucher.reload.voucher_redeemed?

      result = Invoices::GenerationService.new.call

      assert result.success?, result.message
      invoice = Invoice.find_by!(vendor: @vendor)
      assert_includes invoice.voucher_transactions, first
      assert_includes invoice.voucher_transactions, second
      assert_in_delta 100 + 250.25, invoice.total_amount.to_f

      invoice.update!(status: :invoice_approved)
      invoice.update!(status: :invoice_paid, gad_invoice_reference: 'GAD-TEST-1')

      assert_in_delta 350.25, invoice.reload.total_amount.to_f
      assert_equal [BigDecimal('65'), BigDecimal('35')], [first.reload.amount, second.reload.amount]
      assert_equal [invoice.id], [first.invoice_id, second.invoice_id].uniq
      assert_equal BigDecimal('0'), voucher.reload.remaining_value
    end

    test 'the recurring job commits an invoice and delivers the vendor notice after commit' do
      perform_enqueued_jobs do
        GenerateVendorInvoicesJob.perform_now
      end

      invoice = Invoice.find_by!(vendor: @vendor)
      assert invoice.status_invoice_pending?
      assert_in_delta 250.25, invoice.total_amount.to_f
      assert_equal @transactions.map(&:id).sort, invoice.voucher_transactions.pluck(:id).sort
      assert invoice.events.exists?(action: 'generated')

      mail = ActionMailer::Base.deliveries.find { |delivery| delivery.to == [@vendor.email] }
      assert mail, 'vendor invoice notice was not delivered'
      assert_includes mail.text_part&.decoded || mail.body.decoded, invoice.invoice_number
      assert(mail.attachments.any? { |attachment| attachment.filename == "invoice-#{invoice.invoice_number}.pdf" })
    end

    test 'a failed notice enqueue keeps the committed invoice and reports the delivery problem' do
      EmailDelivery::MailDeliveryJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, 'queue down')

      result = Invoices::GenerationService.new.call

      assert result.success?
      invoice = Invoice.find_by!(vendor: @vendor)
      assert_equal 2, invoice.voucher_transactions.count
      assert invoice.events.exists?(action: 'invoice_notification_enqueue_failed')
      assert Event.exists?(action: EmailDelivery::Outcome::ENQUEUE_FAILED)
      assert_equal 0, ActionMailer::Base.deliveries.size
    end

    test 'with vendor email off the invoice is generated and its notice is suppressed, not failed' do
      EmailDelivery::ControlWriter.set(name: EmailDelivery.category_control('vendor'), enabled: false, actor: @admin,
                                       operation_id: 'op-1')

      Invoices::GenerationService.new.call

      invoice = Invoice.find_by!(vendor: @vendor)
      assert_in_delta 250.25, invoice.total_amount.to_f
      assert_not invoice.events.exists?(action: 'invoice_notification_enqueue_failed')
      assert_equal 'category_disabled', Event.find_by!(action: EmailDelivery::Outcome::SUPPRESSED).metadata['reason']
      assert_equal(0, enqueued_jobs.count { |job| job[:job] == EmailDelivery::MailDeliveryJob })
    end

    test 'the service reports each notice outcome' do
      service = Invoices::GenerationService.new
      invoice = create(:invoice, vendor: @vendor)

      assert_equal :queued, service.send(:queue_vendor_notification, invoice)

      EmailDelivery::MailDeliveryJob.queue_adapter.stubs(:enqueue).raises(ActiveJob::EnqueueError, 'queue down')
      assert_equal :enqueue_failed, service.send(:queue_vendor_notification, invoice)
      EmailDelivery::MailDeliveryJob.queue_adapter.unstub(:enqueue)

      EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: false, actor: @admin, operation_id: 'op-1')
      assert_equal :suppressed, service.send(:queue_vendor_notification, invoice)

      FeatureFlag.find_by!(name: EmailDelivery::GLOBAL_CONTROL).destroy!
      assert_equal :configuration_error, service.send(:queue_vendor_notification, invoice)
    end

    test 'unavailable email settings keep the invoice and report a configuration error' do
      FeatureFlag.find_by!(name: EmailDelivery.category_control('vendor')).destroy!

      result = Invoices::GenerationService.new.call

      assert result.success?
      invoice = Invoice.find_by!(vendor: @vendor)
      assert_equal 2, invoice.voucher_transactions.count
      assert_not invoice.events.exists?(action: 'invoice_notification_enqueue_failed')
      assert Event.exists?(action: EmailDelivery::Outcome::CONFIGURATION_ERROR)
      assert_not Event.exists?(action: EmailDelivery::Outcome::SUPPRESSED)
      assert_empty enqueued_jobs
      assert_empty ActionMailer::Base.deliveries
    end

    test 'a later cycle invoices new transactions after the previous invoice' do
      Invoices::GenerationService.new.call
      first = Invoice.find_by!(vendor: @vendor)

      travel_to(first.end_date + 1.hour) do
        later = create(:voucher_transaction, vendor: @vendor, amount: 40, processed_at: Time.current)
        result = Invoices::GenerationService.new.call

        assert_equal 1, result.data[:invoices_created]
        second = Invoice.for_vendor(@vendor.id).where.not(id: first.id).sole
        assert_equal [later.id], second.voucher_transactions.pluck(:id)
      end
    end
  end
end
