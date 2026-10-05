# frozen_string_literal: true

require 'test_helper'

class VoucherRedemptionTest < ActiveSupport::TestCase
  setup do
    @application = create(:application, :completed)
    @constituent = @application.user
    @vendor = create(:vendor)

    @voucher = create(:voucher, application: @application, initial_value: 500, remaining_value: 500)

    @product1 = create(:product, name: 'Test Product A')
    @product2 = create(:product, name: 'Test Product B')
  end

  test 'voucher redemption creates transaction record' do
    assert_difference -> { VoucherTransaction.count }, 1 do
      @voucher.redeem!(100, @vendor)
    end

    txn = VoucherTransaction.last
    assert_equal 100, txn.amount
    assert_equal @vendor, txn.vendor
    assert_equal 'redemption', txn.transaction_type
    assert_equal 'transaction_completed', txn.status
  end

  test 'voucher redemption updates voucher remaining value' do
    @voucher.redeem!(100, @vendor)
    @voucher.reload

    assert_equal 400, @voucher.remaining_value
    assert_equal @vendor, @voucher.vendor
    assert_not_nil @voucher.last_used_at
  end

  test 'voucher redemption calls the audit service and updates the voucher' do
    # Redemption and status changes can each call the audit service.

    AuditEventService.expects(:log).at_least_once.returns(nil)

    @voucher.redeem!(100, @vendor)

    @voucher.reload
    assert_equal 400, @voucher.remaining_value
    assert_equal @vendor, @voucher.vendor
  end

  test 'voucher redemption sends email notification' do
    assert_enqueued_emails 1 do
      @voucher.redeem!(100, @vendor)
    end
  end

  test 'voucher redemption with products associates products' do
    product_data = { @product1.id.to_s => 1, @product2.id.to_s => 2 }

    mock_event = mock('event')
    mock_event.stubs(:metadata).returns({ 'products' => [{ 'id' => @product1.id.to_s, 'quantity' => 1 },
                                                         { 'id' => @product2.id.to_s, 'quantity' => 2 }] })
    events_association = mock('events_association')
    events_association.stubs(:create!).returns(mock_event)
    @voucher.stubs(:events).returns(events_association)

    @voucher.redeem!(100, @vendor, product_data)

    @application.reload
    assert_includes @application.products, @product1
    assert_includes @application.products, @product2

    txn = VoucherTransaction.last
    assert_equal 2, txn.voucher_transaction_products.count

    assert_not_nil mock_event.metadata['products']
    assert_equal 2, mock_event.metadata['products'].size
  end

  test "fault-tolerant event logging doesn't prevent redemption" do
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with(regexp_matches(/Failed to log voucher redemption event: Simulated audit error/)).once

    AuditEventService.stubs(:log).raises(StandardError, 'Simulated audit error')

    assert_difference -> { VoucherTransaction.count }, 1 do
      @voucher.redeem!(100, @vendor)
    end

    @voucher.reload
    assert_equal 400, @voucher.remaining_value
  end

  test 'full redemption sets voucher status to redeemed' do
    @voucher.redeem!(@voucher.remaining_value, @vendor)
    @voucher.reload

    assert_equal 'redeemed', @voucher.status
    assert_equal 0, @voucher.remaining_value
  end

  test 'cannot redeem more than remaining value' do
    result = @voucher.redeem!(@voucher.remaining_value + 1, @vendor)
    assert_equal false, result

    @voucher.reload
    assert_equal 500, @voucher.remaining_value
  end

  test 'cannot redeem below minimum amount' do
    min_amount = Policy.voucher_minimum_redemption_amount
    result = @voucher.redeem!(min_amount - 0.01, @vendor)
    assert_equal false, result

    @voucher.reload
    assert_equal 500, @voucher.remaining_value
  end
end
