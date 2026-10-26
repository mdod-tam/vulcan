# frozen_string_literal: true

require 'test_helper'

class VoucherStatusTest < ActiveSupport::TestCase
  test 'voucher activation from active state' do
    voucher = FactoryBot.create(:voucher, status: :active)

    assert_equal 'active', voucher.status

    voucher.activate_if_valid!

    assert_equal 'active', voucher.status
  end

  test "voucher status enum doesn't contain issued" do
    assert_not Voucher.statuses.key?('issued')
  end

  test 'voucher default status is active' do
    voucher = FactoryBot.create(:voucher)

    assert_equal 'active', voucher.status
  end
end
