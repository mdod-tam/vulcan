# frozen_string_literal: true

require 'test_helper'

class InvoiceTest < ActiveSupport::TestCase
  setup do
    @vendor = create(:vendor)
    @invoice = create(:invoice,
                      vendor: @vendor,
                      start_date: 4.weeks.ago.beginning_of_day,
                      end_date: 2.weeks.ago.end_of_day)
  end

  test 'valid invoice' do
    assert @invoice.valid?
  end

  test 'requires vendor' do
    @invoice.vendor = nil
    assert_not @invoice.valid?
    assert_includes @invoice.errors[:vendor], 'must exist'
  end

  test 'requires period dates' do
    @invoice.start_date = nil
    @invoice.end_date = nil
    assert_not @invoice.valid?
    assert_includes @invoice.errors[:start_date], "can't be blank"
    assert_includes @invoice.errors[:end_date], "can't be blank"
  end

  test 'end date must be after start date' do
    @invoice.start_date = Time.current
    @invoice.end_date = 1.day.ago
    assert_not @invoice.valid?
    assert_includes @invoice.errors[:end_date], 'must be after start date'
  end

  test 'requires GAD reference when paid' do
    @invoice.status = :invoice_paid
    assert_not @invoice.valid?
    assert_includes @invoice.errors[:gad_invoice_reference], "can't be blank"

    @invoice.gad_invoice_reference = 'GAD-123456'
    assert @invoice.valid?
  end

  test 'sets approved_at timestamp when approved' do
    freeze_time do
      @invoice.update!(status: :invoice_approved)
      assert_equal Time.current, @invoice.approved_at
    end
  end

  test 'sets payment_recorded_at timestamp when paid' do
    freeze_time do
      @invoice.update!(
        status: :invoice_approved,
        approved_at: 1.day.ago
      )

      @invoice.update!(
        status: :invoice_paid,
        gad_invoice_reference: 'GAD-123456'
      )

      assert_equal Time.current, @invoice.payment_recorded_at
    end
  end

  test 'sends payment notification when payment details added' do
    @invoice.update!(status: :invoice_approved)

    assert_enqueued_jobs 1, only: EmailDelivery::MailDeliveryJob do
      @invoice.update!(
        status: :invoice_paid,
        gad_invoice_reference: 'GAD-123456'
      )
    end
  end

  test 'paying an invoice leaves its transactions and their vouchers unchanged' do
    @invoice = create(:invoice, :with_transactions, transaction_count: 2)
    vouchers = @invoice.voucher_transactions.map(&:voucher)
    vouchers.first.update!(remaining_value: 25)
    before = voucher_states(vouchers)
    transactions_before = @invoice.voucher_transactions.order(:id).pluck(:id, :status, :amount)

    @invoice.update!(status: :invoice_approved)
    @invoice.update!(status: :invoice_paid, gad_invoice_reference: 'GAD-123456')

    assert_equal before, voucher_states(vouchers)
    assert_equal transactions_before, @invoice.voucher_transactions.order(:id).pluck(:id, :status, :amount)
    assert(vouchers.first.voucher_active?, 'a voucher with a balance stays usable after the vendor is paid')
  end

  test 'generates unique invoice numbers' do
    invoice1 = create(:invoice)
    invoice2 = create(:invoice)

    assert_not_equal invoice1.invoice_number, invoice2.invoice_number
    assert_match(/\AINV-\d{6}-[A-F0-9]+\z/, invoice1.invoice_number)
    assert_match(/\AINV-\d{6}-[A-F0-9]+\z/, invoice2.invoice_number)
  end

  test 'prevents overlapping periods for same vendor' do
    period_start = Time.current.beginning_of_day
    period_end = 2.weeks.from_now.end_of_day

    create(:invoice,
           vendor: @vendor,
           start_date: period_start,
           end_date: period_end)

    overlapping = build(:invoice,
                        vendor: @vendor,
                        start_date: 1.week.from_now.beginning_of_day,
                        end_date: 3.weeks.from_now.end_of_day)

    assert_not overlapping.valid?
    assert_includes overlapping.errors[:base], 'Date range overlaps with an existing invoice'
  end

  test 'allows same period for different vendors' do
    period_start = Time.current.beginning_of_day
    period_end = 2.weeks.from_now.end_of_day

    create(:invoice,
           vendor: @vendor,
           start_date: period_start,
           end_date: period_end)

    other_vendor = create(:vendor)
    other_invoice = build(:invoice,
                          vendor: other_vendor,
                          start_date: period_start,
                          end_date: period_end)

    assert other_invoice.valid?
  end

  test 'allows the next period to start where the previous one ended' do
    period_end = 2.weeks.from_now.end_of_day
    create(:invoice, vendor: @vendor, start_date: Time.current.beginning_of_day, end_date: period_end)

    next_invoice = build(:invoice, vendor: @vendor, start_date: period_end, end_date: 4.weeks.from_now.end_of_day)

    assert next_invoice.valid?, next_invoice.errors.full_messages.to_sentence
  end

  private

  def voucher_states(vouchers)
    vouchers.map { |voucher| voucher.reload.attributes.slice('status', 'remaining_value') }
  end
end
