# frozen_string_literal: true

require 'test_helper'

class AuthRateLimitTest < ActiveSupport::TestCase
  setup do
    @old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @request = Struct.new(:remote_ip).new('203.0.113.10')
    @contact = 'user@example.com'
    @contact_digest = AuthRateLimit.contact_digest(@contact)
    @ip_digest = AuthRateLimit.request_ip_digest(@request)
    @identifier = AuthRateLimit.cache_identifier(
      contact_digest: @contact_digest,
      request_ip_digest: @ip_digest
    )

    ensure_auth_rate_limit_policy('account_access_rate_limit_contact_ip', 2)
    ensure_auth_rate_limit_policy('account_access_rate_period', 1)
  end

  teardown do
    Rails.cache = @old_cache
  end

  test 'contact digest is stable and does not include raw contact' do
    digest = AuthRateLimit.contact_digest(@contact)

    assert digest.present?
    assert_not_includes digest, @contact
  end

  test 'contact digest canonicalizes email case' do
    assert_equal AuthRateLimit.contact_digest('User@Example.com'), AuthRateLimit.contact_digest('user@example.com')
  end

  test 'contact digest canonicalizes phone punctuation' do
    assert_equal AuthRateLimit.contact_digest('4105550198'), AuthRateLimit.contact_digest('410-555-0198')
  end

  test 'check derives digested cache key without raw ip or contact' do
    AuthRateLimit.check!(
      action: :account_access,
      scope: :contact_ip,
      request: @request,
      submitted_contact: @contact
    )

    assert Rails.cache.read("auth_rate_limit:account_access:contact_ip:#{@identifier}").present?
    assert_not_includes @identifier, @request.remote_ip
    assert_not_includes @identifier, @contact
  end

  test 'request ip digest is keyed and not plain sha256' do
    digest = AuthRateLimit.request_ip_digest(@request)

    assert_equal 64, digest.length
    assert_not_equal Digest::SHA256.hexdigest(@request.remote_ip), digest
  end

  test 'rejects unknown auth rate limit scope' do
    assert_nil AuthRateLimit.limit_config_for(:account_access, :unknown_scope)

    assert_raises(ArgumentError) do
      AuthRateLimit.check!(
        action: :account_access,
        scope: :unknown_scope,
        request: @request,
        submitted_contact: @contact
      )
    end
  end

  test 'increment first enforcement blocks the request that exceeds the limit' do
    2.times do
      AuthRateLimit.check!(
        action: :account_access,
        scope: :contact_ip,
        request: @request,
        submitted_contact: @contact
      )
    end

    assert_raises(AuthRateLimit::ExceededError) do
      AuthRateLimit.check!(
        action: :account_access,
        scope: :contact_ip,
        request: @request,
        submitted_contact: @contact
      )
    end
  end

  test 'uses centralized defaults when all auth policy rows are missing' do
    Policy.where(key: Policy::RATE_LIMIT_KEYS.select { |key| key.start_with?('sign_in_', 'account_access_', 'account_recovery_') }).delete_all

    20.times do
      AuthRateLimit.check!(
        action: :sign_in_attempt,
        scope: :ip,
        request: @request
      )
    end

    assert_raises(AuthRateLimit::ExceededError) do
      AuthRateLimit.check!(
        action: :sign_in_attempt,
        scope: :ip,
        request: @request
      )
    end
  end

  test 'normalizes invalid policy max to centralized default' do
    policy = Policy.find_or_create_by!(key: 'account_access_rate_limit_contact_ip') { |record| record.value = 2 }
    policy.update_column(:value, 0)

    limit = AuthRateLimit.limit_config_for(:account_access, :contact_ip)

    assert_equal AuthRateLimit.default_max(:account_access, :contact_ip), limit[:max]
  end

  test 'uses seeded policy rows when present' do
    ensure_auth_rate_limit_policy('account_access_rate_limit_contact_ip', 2)
    ensure_auth_rate_limit_policy('account_access_rate_period', 1)

    limit = AuthRateLimit.limit_config_for(:account_access, :contact_ip)

    assert_equal 2, limit[:max]
    assert_equal 1.hour, limit[:period]
  end

  test 'user_ip scope derives identifier from request and user id' do
    user = create(:constituent)
    expected_identifier = AuthRateLimit.cache_identifier(
      contact_digest: 'user',
      request_ip_digest: @ip_digest,
      user_id: user.id
    )

    AuthRateLimit.check!(
      action: :account_access,
      scope: :user_ip,
      request: @request,
      user_id: user.id
    )

    assert Rails.cache.read("auth_rate_limit:account_access:user_ip:#{expected_identifier}").present?
  end

  test 'rejects raw contact values passed as identifier' do
    assert_raises(ArgumentError) do
      AuthRateLimit.new(
        action: :account_access,
        scope: :contact_ip,
        identifier: @contact
      )
    end
  end

  def ensure_auth_rate_limit_policy(key, value)
    policy = Policy.find_or_initialize_by(key: key)
    if policy.new_record?
      policy.value = value
      policy.save!
    else
      policy.update_column(:value, value)
    end
  end
end
