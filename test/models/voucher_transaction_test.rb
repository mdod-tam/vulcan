# frozen_string_literal: true

require 'test_helper'

class VoucherTransactionTest < ActiveSupport::TestCase
  setup do
    @vendor = create(:vendor)
    @voucher = create(:voucher, :active, initial_value: 500, remaining_value: 500)
    @transaction = create(:voucher_transaction,
                          voucher: @voucher,
                          vendor: @vendor,
                          amount: 100)
  end

  test 'valid transaction' do
    assert @transaction.valid?
  end

  test 'requires voucher' do
    transaction = build(:voucher_transaction, voucher: nil, vendor: @vendor, amount: 100)
    assert_not transaction.valid?
    assert_includes transaction.errors[:voucher], 'must exist'
  end

  test 'requires vendor' do
    transaction = build(:voucher_transaction, voucher: @voucher, vendor: nil, amount: 100)
    assert_not transaction.valid?
    assert_includes transaction.errors[:vendor], 'must exist'
  end

  # Amounts are set once, on a new transaction; see VoucherTransactionImmutabilityTest.
  test 'requires amount' do
    transaction = build(:voucher_transaction, voucher: @voucher, vendor: @vendor, amount: nil)
    assert_not transaction.valid?
    assert_includes transaction.errors[:amount], "can't be blank"
  end

  test 'requires positive amount' do
    [0, -50].each do |amount|
      transaction = build(:voucher_transaction, voucher: @voucher, vendor: @vendor, amount: amount)
      assert_not transaction.valid?
      assert_includes transaction.errors[:amount], 'must be greater than 0'
    end
  end

  test 'reference number cannot be cleared once saved' do
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @transaction.reference_number = nil }
  end

  test 'requires unique reference number' do
    duplicate = build(:voucher_transaction, reference_number: @transaction.reference_number)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:reference_number], 'has already been taken'
  end

  test 'processed_at cannot be cleared once saved' do
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @transaction.processed_at = nil }
  end

  test 'sets processed_at on create' do
    transaction = build(:voucher_transaction, processed_at: nil)
    freeze_time do
      transaction.save!
      assert_equal Time.current, transaction.processed_at
    end
  end

  test 'validates redemption amount within voucher limit' do
    transaction = build(:voucher_transaction,
                        voucher: @voucher,
                        amount: 600,
                        transaction_type: :redemption)
    assert_not transaction.valid?
    assert_includes transaction.errors[:amount], 'exceeds remaining voucher value'
  end

  test 'allows redemption up to remaining value' do
    transaction = build(:voucher_transaction,
                        voucher: @voucher,
                        amount: @voucher.remaining_value,
                        transaction_type: :redemption)
    assert transaction.valid?
  end

  test 'completed scope returns only completed transactions' do
    test_vendor = create(:vendor)
    completed = create(:voucher_transaction, vendor: test_vendor, status: :transaction_completed)
    pending = create(:voucher_transaction, vendor: test_vendor, status: :transaction_pending)
    failed = create(:voucher_transaction, vendor: test_vendor, status: :transaction_failed)

    completed_transactions = VoucherTransaction.where(vendor: test_vendor).completed
    assert_includes completed_transactions, completed
    assert_not_includes completed_transactions, pending
    assert_not_includes completed_transactions, failed
  end

  test 'pending_invoice scope returns completed transactions without invoice' do
    test_vendor = create(:vendor)
    with_invoice = create(:voucher_transaction,
                          vendor: test_vendor,
                          status: :transaction_completed,
                          invoice: create(:invoice))
    without_invoice = create(:voucher_transaction,
                             vendor: test_vendor,
                             status: :transaction_completed,
                             invoice: nil)
    pending = create(:voucher_transaction,
                     vendor: test_vendor,
                     status: :transaction_pending,
                     invoice: nil)

    pending_transactions = VoucherTransaction.where(vendor: test_vendor).pending_invoice
    assert_includes pending_transactions, without_invoice
    assert_not_includes pending_transactions, with_invoice
    assert_not_includes pending_transactions, pending
  end

  test 'for_vendor scope returns transactions for specific vendor' do
    test_vendor = create(:vendor)
    other_vendor = create(:vendor)
    vendor_transaction = create(:voucher_transaction, vendor: test_vendor)
    other_transaction = create(:voucher_transaction, vendor: other_vendor)

    assert_includes VoucherTransaction.for_vendor(test_vendor.id), vendor_transaction
    assert_not_includes VoucherTransaction.for_vendor(test_vendor.id), other_transaction
  end

  test 'in_date_range scope returns transactions within range' do
    test_vendor = create(:vendor)
    past = create(:voucher_transaction, vendor: test_vendor, processed_at: 2.weeks.ago)
    current = create(:voucher_transaction, vendor: test_vendor, processed_at: Time.current)
    future = create(:voucher_transaction, vendor: test_vendor, processed_at: 2.weeks.from_now)

    start_date = 1.week.ago
    end_date = 1.week.from_now

    transactions = VoucherTransaction.where(vendor: test_vendor).in_date_range(start_date, end_date)
    assert_includes transactions, current
    assert_not_includes transactions, past
    assert_not_includes transactions, future
  end

  test 'total_amount_for_vendor calculates sum for completed transactions' do
    test_vendor = create(:vendor)
    create(:voucher_transaction,
           vendor: test_vendor,
           amount: 100,
           status: :transaction_completed)
    create(:voucher_transaction,
           vendor: test_vendor,
           amount: 200,
           status: :transaction_completed)
    create(:voucher_transaction,
           vendor: test_vendor,
           amount: 50,
           status: :transaction_pending)

    assert_equal 300, VoucherTransaction.total_amount_for_vendor(test_vendor.id)
  end

  test 'transaction_counts_by_status groups transactions' do
    test_vendor = create(:vendor)
    create(:voucher_transaction, vendor: test_vendor, status: :transaction_completed)
    create(:voucher_transaction, vendor: test_vendor, status: :transaction_completed)
    create(:voucher_transaction, vendor: test_vendor, status: :transaction_pending)
    create(:voucher_transaction, vendor: test_vendor, status: :transaction_failed)

    counts = VoucherTransaction.transaction_counts_by_status(test_vendor.id)
    assert_equal 2, counts['transaction_completed']
    assert_equal 1, counts['transaction_pending']
    assert_equal 1, counts['transaction_failed']
  end

  test 'needing_shipping_details matches needs_shipping_details? for every fulfillment state' do
    vendor = create(:vendor)
    unspecified = create(:voucher_transaction, vendor: vendor)
    shipping_without_packages = create(:voucher_transaction, vendor: vendor, fulfillment_mode: :shipping)
    shipped = create(:voucher_transaction, vendor: vendor)
    VoucherTransactions::FulfillmentService.new(transaction: shipped, actor: vendor)
                                           .add_shipment!(attributes: { 'tracking_number' => 'AAA111' }, expected_version: 0)
    pickup = create(:voucher_transaction, vendor: vendor, fulfillment_mode: :local_pickup)
    pending = create(:voucher_transaction, :pending, vendor: vendor)

    listed = VoucherTransaction.for_vendor(vendor.id).needing_shipping_details
    [unspecified, shipping_without_packages, shipped, pickup, pending].each do |purchase|
      assert_equal purchase.reload.needs_shipping_details?, listed.include?(purchase), purchase.inspect
    end
    assert_equal [unspecified, shipping_without_packages].map(&:id).sort, listed.pluck(:id).sort
  end

  test 'purchases_visible_to lists completed purchases on applications the user may open' do
    own = create(:application)
    managed = create(:application, :for_dependent)
    own_purchase = create(:voucher_transaction, voucher: create(:voucher, application: own))
    managed_purchase = create(:voucher_transaction, voucher: create(:voucher, application: managed))
    create(:voucher_transaction, :pending, voucher: create(:voucher, application: own))

    assert_equal [own_purchase], VoucherTransaction.purchases_visible_to(own.user).to_a
    assert_equal [managed_purchase], VoucherTransaction.purchases_visible_to(managed.managing_guardian).to_a
    assert_empty VoucherTransaction.purchases_visible_to(managed.user), 'a managed application is listed for its guardian, not its applicant'
  end

  test 'daily_totals calculates daily sums for completed transactions' do
    test_vendor = create(:vendor, email: 'daily_totals_test@example.com')

    # Run this test in complete isolation
    VoucherTransaction.transaction do
      VoucherTransaction.delete_all

      freeze_time do
        # Create a simple transaction with a known amount
        voucher = create(:voucher, :active, initial_value: 1000, remaining_value: 1000)

        # Create transaction bypassing factory callbacks that might interfere
        tx = VoucherTransaction.new(
          voucher: voucher,
          vendor: test_vendor,
          amount: BigDecimal('50.00'), # Use 50 to avoid confusion with setup
          status: :transaction_completed,
          processed_at: Time.current,
          reference_number: 'DAILY-TEST-001'
        )
        tx.save!

        # Verify the amount was stored correctly
        stored_tx = VoucherTransaction.find(tx.id)
        assert_equal 50, stored_tx.amount.to_i, "Transaction should have amount 50, got #{stored_tx.amount}"

        totals = VoucherTransaction.daily_totals(1.day.ago, Time.current, test_vendor.id)
        assert_equal 50, totals[Time.current.to_date], "Daily total should be 50, got #{totals[Time.current.to_date]}"
      end

      raise ActiveRecord::Rollback # Clean up
    end
  end
end
