# frozen_string_literal: true

require 'test_helper'

class PolicyTest < ActiveSupport::TestCase
  # 0 would lock a vendor out of a voucher on the first wrong date of birth.
  test 'voucher verification attempts must be between 1 and 100' do
    policy = Policy.find_or_initialize_by(key: 'voucher_verification_max_attempts')

    [0, -1, 101].each do |value|
      policy.value = value
      assert_not policy.valid?, value.to_s
    end
    policy.value = 3
    assert policy.valid?
  end
end
