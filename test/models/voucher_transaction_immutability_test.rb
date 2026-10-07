# frozen_string_literal: true

require 'test_helper'

# A transaction's balance check runs only when it is created, so its money fields must not change after.
class VoucherTransactionImmutabilityTest < ActiveSupport::TestCase
  setup do
    Policy.stubs(:voucher_minimum_redemption_amount).returns(10)
    @vendor = create(:vendor, :approved)
    @voucher = create(:voucher, initial_value: 100, remaining_value: 100, vendor: nil)
    @transaction = @voucher.redeem!(60, @vendor)
  end

  {
    amount: 1,
    voucher_id: -> { create(:voucher).id },
    vendor_id: -> { create(:vendor, :approved).id },
    transaction_type: :refund,
    reference_number: 'TX-CHANGED',
    processed_at: -> { 1.year.ago }
  }.each do |field, value|
    test "#{field} cannot change once saved" do
      new_value = value.respond_to?(:call) ? instance_exec(&value) : value

      assert_raises(ActiveRecord::ReadonlyAttributeError) { @transaction.update!(field => new_value) }
    end
  end

  test 'linking to an invoice still saves after the voucher is spent down' do
    @voucher.redeem!(40, @vendor)
    invoice = create(:invoice, vendor: @vendor)

    assert @transaction.reload.update!(invoice_id: invoice.id)
  end

  test 'a new redemption above the balance is still refused' do
    assert_equal false, @voucher.reload.redeem!(41, @vendor)
    assert_raises(ActiveRecord::RecordInvalid) do
      @voucher.transactions.create!(vendor: @vendor, amount: 41, transaction_type: :redemption,
                                    status: :transaction_completed)
    end
  end
end
