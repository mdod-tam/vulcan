# frozen_string_literal: true

require 'test_helper'

class VoucherStatusTest < ActiveSupport::TestCase
  test "voucher status enum doesn't contain issued" do
    assert_not Voucher.statuses.key?('issued')
  end

  test 'voucher statuses are numbered without a gap, as the status migration leaves them' do
    assert_equal({ 'active' => 0, 'redeemed' => 1, 'expired' => 2, 'cancelled' => 3 }, Voucher.statuses.to_h)

    Voucher.statuses.each do |name, stored|
      voucher = FactoryBot.create(:voucher, status: name)
      assert_equal stored, Voucher.connection.select_value(Voucher.where(id: voucher.id).select(:status).to_sql)
    end
  end

  test 'voucher default status is active' do
    voucher = FactoryBot.create(:voucher)

    assert_equal 'active', voucher.status
  end
end
