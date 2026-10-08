# frozen_string_literal: true

module VoucherTestHelper
  def create_redeemed_voucher(vendor:, amount:)
    voucher = create(:voucher, :active)
    transaction = create(:voucher_transaction,
                         voucher: voucher,
                         vendor: vendor,
                         amount: amount,
                         status: :transaction_completed)

    invoice = create(:invoice, :pending, vendor: vendor, voucher_transactions: [transaction])
    pay_invoice!(invoice)

    voucher.reload
  end

  def create_pending_invoice(vendor:, transaction_count: 3, amount: 100.00)
    create(:invoice, :pending,
           vendor: vendor,
           voucher_transactions: create_list(:voucher_transaction, transaction_count,
                                             vendor: vendor,
                                             amount: amount,
                                             status: :transaction_pending))
  end

  def approve_and_record_payment(invoice:, gad_reference: nil)
    pay_invoice!(invoice, gad_invoice_reference: gad_reference || "GAD-#{SecureRandom.hex(6).upcase}",
                          payment_method: 'check', check_number: "CHK#{SecureRandom.hex(4).upcase}",
                          payment_notes: 'Payment processed by GAD')
  end

  def sign_in_vendor(vendor)
    session = vendor.sessions.create!(
      user_agent: 'Rails Testing',
      ip_address: '127.0.0.1'
    )
    cookies.signed[:session_token] = {
      value: session.session_token,
      httponly: true,
      expires: 30.days.from_now
    }
  end

  def assert_voucher_redeemed(voucher, amount)
    assert_equal 0, voucher.reload.remaining_value
    assert_equal 'redeemed', voucher.status
    assert_equal amount, voucher.voucher_transactions.sum(:amount)
  end

  def assert_transaction_created(voucher:, vendor:, amount:)
    transaction = voucher.voucher_transactions.last
    assert transaction.present?
    assert_equal vendor, transaction.vendor
    assert_equal amount, transaction.amount
    assert_equal 'transaction_completed', transaction.status
  end

  def assert_invoice_generated(vendor:)
    invoice = vendor.invoices.last
    assert invoice.present?
    assert_equal 'invoice_pending', invoice.status
    assert invoice.total_amount.positive?
    assert invoice.voucher_transactions.any?
  end

  def assert_valid_pdf_response
    assert_equal 'application/pdf', response.content_type
    assert response.body.start_with?('%PDF')
  end

  def assert_valid_csv_response
    assert_equal 'text/csv', response.content_type
    assert_includes response.body, 'Invoice Number,Vendor,Total Amount,Status,GAD Reference'
  end

  def assert_invoice_paid(invoice)
    assert invoice.reload.status_invoice_paid?
    assert invoice.payment_recorded_at.present?
    assert invoice.gad_invoice_reference.present?
    assert(invoice.voucher_transactions.all?(&:transaction_completed?))
  end

  def assert_dashboard_elements
    assert_selector "[data-test-id='pending-payment']"
    assert_selector "[data-test-id='monthly-total']"
    assert_selector "[data-test-id='recent-transactions']"
    assert_selector "[data-test-id='chart']"
  end

  def assert_profile_complete(vendor)
    assert vendor.business_name.present?
    assert vendor.business_tax_id.present?
    assert vendor.w9_form.attached?
    assert vendor.terms_accepted_at.present?
  end

  def sample_w9_file
    fixture_file_upload(
      Rails.root.join('test/fixtures/files/sample_w9.txt'),
      'text/plain'
    )
  end

  def valid_voucher_params(vendor)
    {
      vendor_id: vendor.id,
      initial_value: 500.00,
      code: SecureRandom.alphanumeric(12).upcase,
      status: :active,
      issued_at: Time.current,
      expiration_date: 6.months.from_now
    }
  end

  def valid_transaction_params(voucher:, amount:)
    {
      voucher_id: voucher.id,
      amount: amount,
      status: :transaction_completed,
      processed_at: Time.current,
      reference_number: SecureRandom.hex(8).upcase
    }
  end
end
