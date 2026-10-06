# frozen_string_literal: true

require 'test_helper'

module Vouchers
  # Eligibility used to be relaxed in the test environment, so no test could catch a regression in
  # the W9 requirement. It is now the same rule everywhere.
  class RedemptionServiceTest < ActiveSupport::TestCase
    setup do
      FeatureFlag.enable!(:vouchers_enabled)
      @voucher = create(:voucher, :active)
      @session = { verified_vouchers: [@voucher.id] }
    end

    test 'an approved vendor whose W9 is not approved cannot redeem' do
      vendor = create(:vendor, :approved).tap { |approved| approved.update_column(:w9_status, :pending_review) }
      result = redeem(vendor)

      assert result.failure?
      assert_equal 'Your account is not approved for processing vouchers yet', result.message
    end

    test 'a vendor awaiting approval cannot redeem' do
      assert redeem(create(:vendor, :pending)).failure?
    end

    private

    def redeem(vendor)
      RedemptionService.call(voucher: @voucher, vendor: vendor, amount: 10, product_ids: [], session: @session)
    end
  end
end
