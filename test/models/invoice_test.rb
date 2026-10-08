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

  test 'a payment must record its date, method, reference, and GAD reference' do
    approve_invoice!(@invoice)
    @invoice.status = :invoice_paid

    assert_not @invoice.valid?
    %i[payment_date payment_method paid_by gad_invoice_reference].each do |field|
      assert_includes @invoice.errors[field], "can't be blank", field
    end

    @invoice.payment_method = 'check'
    @invoice.valid?
    assert_includes @invoice.errors[:check_number], "can't be blank"
  end

  test 'only the workflow transitions are allowed, and paid is final' do
    @invoice.update!(status: :invoice_pending)
    assert_not @invoice.update(status: :invoice_paid), 'pending cannot jump to paid'

    pay_invoice!(@invoice)
    %i[invoice_approved invoice_pending invoice_cancelled].each do |status|
      assert_not @invoice.reload.update(status: status), "paid cannot become #{status}"
    end
  end

  test 'approval fixes what was billed, and payment fixes how it was settled' do
    approve_invoice!(@invoice)
    assert_not @invoice.update(total_amount: 1)
    assert_includes @invoice.errors[:total_amount], 'cannot change after the invoice is approved'

    pay_invoice!(@invoice.reload)
    assert_not @invoice.update(payment_reference: 'changed')
    assert_includes @invoice.errors[:payment_reference], 'cannot change after payment is recorded'
  end

  test 'issued invoices cannot be deleted' do
    @invoice.update!(status: :invoice_pending)

    assert_not @invoice.destroy
    assert Invoice.exists?(@invoice.id)
  end

  test 'a paid invoice created before payment details existed keeps its unknown values' do
    historical = create(:invoice, :paid, gad_invoice_reference: 'GAD-OLD')

    assert historical.valid?
    assert_nil historical.payment_method
    assert_nil historical.paid_by_id
  end

  test 'paying an invoice leaves its transactions and their vouchers unchanged' do
    @invoice = create(:invoice, :with_transactions, transaction_count: 2)
    vouchers = @invoice.voucher_transactions.map(&:voucher)
    vouchers.first.update!(remaining_value: 25)
    before = voucher_states(vouchers)
    transactions_before = @invoice.voucher_transactions.order(:id).pluck(:id, :status, :amount)

    pay_invoice!(@invoice)

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

  # A catch-up invoice can cover days an earlier invoice also covered; a purchase can still be on only
  # one invoice (see Invoices::GenerationServiceTest).
  test 'allows overlapping periods for the same vendor' do
    create(:invoice, vendor: @vendor, start_date: Time.current.beginning_of_day, end_date: 2.weeks.from_now.end_of_day)

    overlapping = build(:invoice, vendor: @vendor, start_date: 1.week.from_now.beginning_of_day,
                                  end_date: 3.weeks.from_now.end_of_day)

    assert overlapping.valid?, overlapping.errors.full_messages.to_sentence
  end

  test 'the period reads through the last covered day for both exclusive and end-of-day boundaries' do
    exclusive = build(:invoice, start_date: Time.zone.parse('2026-09-24'), end_date: Time.zone.parse('2026-10-08'))
    end_of_day = build(:invoice, start_date: Time.zone.parse('2026-09-24'), end_date: Time.zone.parse('2026-10-07').end_of_day)

    assert_equal 'September 24, 2026 through October 7, 2026', exclusive.period_label
    assert_equal exclusive.period_label, end_of_day.period_label
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
