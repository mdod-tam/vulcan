# frozen_string_literal: true

require 'test_helper'

module Invoices
  # Every completed purchase before the cutoff is invoiced exactly once, whatever runs were missed or failed.
  class GenerationRecoveryTest < ActiveJob::TestCase
    setup do
      ensure_system_audit_actor!
      load_seeded_email_templates('vendor_notifications_invoice_generated')
      @vendor = create(:vendor, :approved)
      @now = Time.zone.parse('2026-10-08 06:00')
      @cutoff = Time.zone.parse('2026-10-08 00:00')
    end

    test 'old purchases from missed runs are invoiced, and the period starts with the oldest one' do
      old = purchase(processed_at: @now - 40.days)
      recent = purchase(processed_at: @now - 2.days)

      result = run_generation

      invoice = Invoice.find_by!(vendor: @vendor)
      assert_equal 1, result.data[:invoices_created]
      assert_equal [old.id, recent.id].sort, invoice.voucher_transactions.pluck(:id).sort
      assert_equal (@now - 40.days).to_date, invoice.start_date.to_date
      assert_equal @cutoff, invoice.end_date
      assert_equal Date.new(2026, 10, 7), invoice.covered_through
      assert_equal old.amount + recent.amount, invoice.total_amount
    end

    test 'a catch-up invoice may cover days an earlier invoice covered, and no purchase is billed twice' do
      billed = purchase(processed_at: @now - 20.days)
      earlier = create(:invoice, vendor: @vendor, start_date: @now - 21.days, end_date: @now - 7.days)
      billed.update!(invoice: earlier)
      late = purchase(processed_at: @now - 15.days) # completed after the earlier invoice was issued

      run_generation

      catch_up = Invoice.for_vendor(@vendor.id).where.not(id: earlier.id).sole
      assert_equal [late.id], catch_up.voucher_transactions.pluck(:id)
      assert_equal earlier.id, billed.reload.invoice_id
    end

    test 'the cutoff is exclusive: a purchase at exactly midnight waits for the next run' do
      before = purchase(processed_at: @cutoff - 1.second)
      at_midnight = purchase(processed_at: @cutoff)

      run_generation

      assert_equal [before.id], Invoice.find_by!(vendor: @vendor).voucher_transactions.pluck(:id)
      assert_nil at_midnight.reload.invoice_id
    end

    test 'a vendor with nothing before the cutoff gets no invoice' do
      purchase(processed_at: @now)

      result = run_generation

      assert_equal 0, result.data[:invoices_created]
      assert_empty Invoice.for_vendor(@vendor.id)
    end

    test 'an invoice-number collision is retried with a new number' do
      purchase(processed_at: @now - 2.days)
      taken = create(:invoice, vendor: create(:vendor), invoice_number: 'INV-202610-AAAAAAAA')
      Invoice.stubs(:generate_number).returns(taken.invoice_number, 'INV-202610-BBBBBBBB')

      run_generation

      assert_equal 'INV-202610-BBBBBBBB', Invoice.find_by!(vendor: @vendor).invoice_number
      assert_empty InvoiceGenerationFailure.unresolved
    end

    test 'a failed vendor is recorded without stopping the others, and a retry resolves it' do
      other_vendor = create(:vendor, :approved)
      purchase(processed_at: @now - 2.days)
      purchase(processed_at: @now - 2.days, vendor: other_vendor)
      failing_vendor_id = @vendor.id
      service = Invoices::GenerationService.new(now: @now)
      service.singleton_class.prepend(Module.new do
        define_method(:create_invoice) do |vendor_id|
          raise ActiveRecord::StatementInvalid, 'simulated' if vendor_id == failing_vendor_id

          super(vendor_id)
        end
      end)

      result = service.call

      assert_equal 1, result.data[:vendors_failed]
      assert Invoice.exists?(vendor: other_vendor)
      failure = InvoiceGenerationFailure.unresolved.find_by!(vendor_id: @vendor.id)
      assert_equal 'ActiveRecord::StatementInvalid', failure.error_category

      Invoices::GenerationService.new(vendor_ids: [@vendor.id], now: @now).call

      assert Invoice.exists?(vendor: @vendor)
      assert failure.reload.resolved_at
    end

    test 'a committed invoice still sends its notice when clearing the retry entry fails' do
      purchase(processed_at: @now - 2.days)
      InvoiceGenerationFailure.record!(vendor_id: @vendor.id, cutoff: @now, error: RuntimeError.new('earlier'))
      InvoiceGenerationFailure.stubs(:resolve!).raises(ActiveRecord::StatementInvalid, 'simulated')

      result = nil
      assert_enqueued_jobs 1, only: EmailDelivery::MailDeliveryJob do
        result = Invoices::GenerationService.new(vendor_ids: [@vendor.id], now: @now).call
      end

      assert_equal [1, 0], result.data.values_at(:invoices_created, :vendors_failed)
      assert Invoice.exists?(vendor: @vendor)
      assert InvoiceGenerationFailure.unresolved.exists?(vendor_id: @vendor.id), 'left for the next run to clear'

      InvoiceGenerationFailure.unstub(:resolve!)
      Invoices::GenerationService.new(vendor_ids: [@vendor.id], now: @now).call
      assert_not InvoiceGenerationFailure.unresolved.exists?(vendor_id: @vendor.id)
      assert_equal 1, Invoice.for_vendor(@vendor.id).count
    end

    # Transactional tests share one connection across threads, so the competing run holds the lock on
    # its own database session.
    test 'a failed vendor whose purchases are now all held is cleared by the next run without an invoice' do
      held = purchase(processed_at: @now - 2.days)
      InvoiceGenerationFailure.record!(vendor_id: @vendor.id, cutoff: @now, error: RuntimeError.new('boom'))
      VoucherTransactions::BillingHold.new(held, actor: create(:admin)).hold!(reason: 'Under review')

      result = Invoices::GenerationService.new(vendor_ids: [@vendor.id], now: @now).call

      assert_equal [0, 0], result.data.values_at(:invoices_created, :vendors_failed)
      assert_empty InvoiceGenerationFailure.unresolved.where(vendor_id: @vendor.id)
      assert_empty Invoice.for_vendor(@vendor.id)
    end

    test 'a run that finds another in progress reports that and changes nothing' do
      purchase(processed_at: @now - 2.days)
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      other_run = PG.connect(dbname: config[:database], host: config[:host], port: config[:port],
                             user: config[:username], password: config[:password])
      other_run.exec("SELECT pg_advisory_lock(#{GenerationService::LOCK_KEY})")

      result = run_generation

      assert result.data[:already_running]
      assert_empty Invoice.for_vendor(@vendor.id)
    ensure
      other_run&.close
    end

    test "a suspended vendor's completed purchases are still invoiced" do
      purchase(processed_at: @now - 2.days)
      @vendor.update_column(:vendor_authorization_status, Users::Vendor.vendor_authorization_statuses[:suspended])

      run_generation

      assert Invoice.exists?(vendor: @vendor)
    end

    private

    def purchase(processed_at:, vendor: @vendor)
      create(:voucher_transaction, vendor: vendor, amount: 25, processed_at: processed_at)
    end

    def run_generation
      Invoices::GenerationService.new(now: @now).call.tap { |result| assert result.success?, result.message }
    end
  end
end
