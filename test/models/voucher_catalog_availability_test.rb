# frozen_string_literal: true

require 'test_helper'

class VoucherCatalogAvailabilityTest < ActiveSupport::TestCase
  setup do
    @voucher = create(:voucher, :active, initial_value: 500, remaining_value: 500, issued_at: Time.current)
    @vendor = create(:vendor, :approved)
    @product = create(:product)
  end

  test 'an unavailable product rolls back the whole new purchase' do
    @product.archive!
    assert_no_difference ['VoucherTransaction.count', 'VoucherTransactionProduct.count'] do
      assert_raises ActiveRecord::RecordInvalid do
        @voucher.redeem!(100, @vendor, { @product.id.to_s => 1 }, submission_id: 'unavailable')
      end
    end
    assert_equal 500, @voucher.reload.remaining_value
  end

  test 'recorded redemption replays after its exact product is discontinued' do
    transaction = @voucher.redeem!(100, @vendor, { @product.id.to_s => 1 }, submission_id: 'recorded')
    @product.archive!
    assert_no_difference ['VoucherTransaction.count', 'VoucherTransactionProduct.count'] do
      replay = @voucher.redeem!(100, @vendor, { @product.id.to_s => 1 }, submission_id: 'recorded')
      assert_equal transaction.id, replay.id
    end
    assert_equal 400, @voucher.reload.remaining_value
  end
end
