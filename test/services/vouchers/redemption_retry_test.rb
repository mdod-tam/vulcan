# frozen_string_literal: true

require 'test_helper'

module Vouchers
  # A redemption form submission records at most one purchase, however often it is sent.
  class RedemptionRetryTest < ActiveJob::TestCase
    setup do
      FeatureFlag.enable!(:vouchers_enabled)
      Policy.stubs(:voucher_minimum_redemption_amount).returns(BigDecimal('10'))
      @vendor = create(:vendor, :approved)
      @voucher = create(:voucher, :active, initial_value: 100, remaining_value: 100, vendor: nil)
      @session = { verified_vouchers: [@voucher.id] }
      @product = create(:product)
      @submission_id = SecureRandom.uuid
    end

    test 'a repeated submission returns the original purchase and charges nothing again' do
      first = redeem('40.00')
      assert first.success?, first.message

      assert_no_difference ['VoucherTransaction.count', 'VoucherTransactionProduct.count',
                            "Event.where(action: 'voucher_redeemed').count"] do
        assert_no_enqueued_jobs do
          replay = redeem('40.00')
          assert replay.success?, replay.message
          assert_equal first.data[:transaction], replay.data[:transaction]
        end
      end

      assert_equal BigDecimal('60'), @voucher.reload.remaining_value
      assert Event.exists?(action: 'voucher_redemption_replayed', auditable: @voucher)
    end

    test 'a replay after the purchase used the whole balance still returns the original purchase' do
      first = redeem('100.00')
      assert first.success?, first.message
      assert @voucher.reload.voucher_redeemed?

      replay = redeem('100.00')

      assert replay.success?, replay.message
      assert_equal first.data[:transaction], replay.data[:transaction]
      assert_equal 1, @voucher.transactions.count
    end

    test 'the same submission with a different amount or products is a conflict, not a second purchase' do
      assert redeem('40.00').success?
      other_product = create(:product)

      [redeem('41.00'), redeem('40.00', product_ids: [other_product.id])].each do |result|
        assert result.failure?
        assert_equal :submission_conflict, result.data[:error_type]
      end
      assert_equal 1, @voucher.transactions.count
      assert_equal BigDecimal('60'), @voucher.reload.remaining_value
    end

    test 'a new submission is a new purchase' do
      assert redeem('40.00').success?
      @submission_id = SecureRandom.uuid

      assert redeem('40.00').success?
      assert_equal 2, @voucher.transactions.count
      assert_equal BigDecimal('20'), @voucher.reload.remaining_value
    end

    test 'amounts are read exactly and refused clearly' do
      { '10.005' => 'Enter the amount in dollars and cents', '1,2' => 'Enter the amount in dollars and cents',
        '0.00' => 'must be greater than zero', '150.00' => 'Cannot redeem more than the available amount',
        '5.00' => 'The minimum redemption amount is' }.each do |input, message|
        result = redeem(input)
        assert result.failure?, input
        assert_includes result.message, message, input
      end
      assert_empty @voucher.transactions

      assert redeem('$1,0.00').failure?
      assert redeem('$19.99').success?
      assert_equal BigDecimal('80.01'), @voucher.reload.remaining_value
    end

    test 'a submission without its form identifier is refused' do
      @submission_id = ''

      result = redeem('40.00')

      assert result.failure?
      assert_includes result.message, 'Reload the redemption form'
      assert_empty @voucher.transactions
    end

    private

    def redeem(amount, product_ids: [@product.id])
      RedemptionService.call(voucher: Voucher.find(@voucher.id), vendor: @vendor, amount: amount, product_ids: product_ids,
                             session: @session, submission_id: @submission_id)
    end
  end
end
