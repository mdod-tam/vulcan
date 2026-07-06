# frozen_string_literal: true

require 'test_helper'

class PolicyAuthRateLimitTest < ActiveSupport::TestCase
  test 'proof submission rate_limit_for returns nil without proof configuration' do
    Policy.where(key: %w[
                   proof_submission_rate_limit_web
                   proof_submission_rate_limit_email
                   proof_submission_rate_period
                 ]).delete_all

    assert_nil Policy.rate_limit_for(:proof_submission, :web)
  end

  test 'proof submission rate_limit_for uses configured proof keys only' do
    Policy.where(key: %w[
                   proof_submission_rate_limit_web
                   proof_submission_rate_limit_email
                   proof_submission_rate_period
                 ]).delete_all

    Policy.create!(key: 'proof_submission_rate_limit_web', value: 7)
    Policy.create!(key: 'proof_submission_rate_period', value: 12)

    limit = Policy.rate_limit_for(:proof_submission, :web)

    assert_equal 7, limit[:max]
    assert_equal 12.hours, limit[:period]
  end

  test 'proof submission rate_limit_for is unaffected by auth policy keys' do
    Policy.where(key: %w[
                   proof_submission_rate_limit_web
                   proof_submission_rate_limit_email
                   proof_submission_rate_period
                 ]).delete_all

    Policy.create!(key: 'proof_submission_rate_limit_web', value: 7)
    Policy.create!(key: 'proof_submission_rate_period', value: 12)
    sign_in_policy = Policy.find_or_initialize_by(key: 'sign_in_attempt_rate_limit_ip')
    if sign_in_policy.new_record?
      sign_in_policy.value = 99
      sign_in_policy.save!
    else
      sign_in_policy.update_column(:value, 99)
    end

    limit = Policy.rate_limit_for(:proof_submission, :web)

    assert_equal 7, limit[:max]
    assert_equal 12.hours, limit[:period]
  end

  test 'auth_rate_limit_for delegates to AuthRateLimit defaults when rows are missing' do
    Policy.where(key: Policy::RATE_LIMIT_KEYS.select { |key| key.start_with?('sign_in_', 'account_access_', 'account_recovery_') }).delete_all

    limit = Policy.auth_rate_limit_for(:account_access, :contact_ip)

    assert_equal AuthRateLimit.default_max(:account_access, :contact_ip), limit[:max]
    assert_equal AuthRateLimit::DEFAULT_PERIOD_HOURS.hours, limit[:period]
  end
end
