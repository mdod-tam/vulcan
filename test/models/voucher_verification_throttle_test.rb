# frozen_string_literal: true

require 'test_helper'

class VoucherVerificationThrottleTest < ActiveSupport::TestCase
  setup do
    @voucher = create(:voucher, :active)
    @vendor = create(:vendor, :approved)
  end

  test 'one row per voucher and vendor' do
    VoucherVerificationThrottle.create!(voucher: @voucher, vendor: @vendor)

    assert_raises(ActiveRecord::RecordNotUnique) do
      VoucherVerificationThrottle.create!(voucher: @voucher, vendor: @vendor)
    end
  end

  test 'reaching the limit locks for the period from the locking failure' do
    freeze_time do
      throttle = VoucherVerificationThrottle.create!(voucher: @voucher, vendor: @vendor)
      2.times { throttle.record_failure!(3) }
      assert_not throttle.locked?

      throttle.record_failure!(3)

      assert throttle.locked?
      assert_equal Time.current + VoucherVerificationThrottle::PERIOD, throttle.locked_until
      assert_equal throttle.locked_until, VoucherVerificationThrottle.locked_until_for(@voucher, @vendor)
    end
  end

  test 'an expired lock is cleared when the row is next used' do
    throttle = VoucherVerificationThrottle.create!(voucher: @voucher, vendor: @vendor)
    3.times { throttle.record_failure!(3) }

    travel VoucherVerificationThrottle::PERIOD + 1.second do
      assert_nil VoucherVerificationThrottle.locked_until_for(@voucher, @vendor)

      VoucherVerificationThrottle.with_row_lock(@voucher, @vendor) do |locked|
        assert_equal 0, locked.failed_attempts
        assert_not locked.locked?
      end
    end
  end

  test 'deleting the voucher removes its throttles' do
    VoucherVerificationThrottle.create!(voucher: @voucher, vendor: @vendor)

    assert_difference('VoucherVerificationThrottle.count', -1) do
      Voucher.where(id: @voucher.id).delete_all
    end
  end
end
