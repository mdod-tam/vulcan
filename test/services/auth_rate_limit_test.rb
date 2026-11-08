# frozen_string_literal: true

require 'test_helper'

class AuthRateLimitTest < ActiveSupport::TestCase
  setup do
    @request = Struct.new(:remote_ip).new('203.0.113.10')
    @contact = 'user@example.com'
    @identifier = AuthRateLimit.cache_identifier(contact_digest: AuthRateLimit.contact_digest(@contact),
                                                 request_ip_digest: AuthRateLimit.request_ip_digest(@request))
    set_policy('account_access_rate_limit_contact_ip', 2)
    set_policy('account_access_rate_period', 1)
  end

  test 'contact keys normalize email and phone without storing the raw identifier' do
    assert_equal AuthRateLimit.contact_digest(' User@Example.com '), AuthRateLimit.contact_digest('user@example.com')
    assert_equal AuthRateLimit.contact_digest('4105550198'), AuthRateLimit.contact_digest('410-555-0198')
    AuthRateLimit.check!(action: :account_access, scope: :contact_ip, request: @request, submitted_contact: @contact)

    key = AuthRateLimitCounter.order(:id).last.key
    assert key.start_with?('auth_rate_limit:account_access:contact_ip:')
    assert_not_includes key, @contact
    assert_not_includes key, @request.remote_ip
  end

  test 'the first request beyond the limit is refused and cache clearing cannot reset it' do
    2.times { AuthRateLimit.check!(action: :account_access, scope: :contact_ip, request: @request, submitted_contact: @contact) }
    Rails.cache.clear

    assert_raises(AuthRateLimit::ExceededError) do
      AuthRateLimit.check!(action: :account_access, scope: :contact_ip, request: @request, submitted_contact: @contact)
    end
    assert_equal 3, AuthRateLimit.new(action: :account_access, scope: :contact_ip, identifier: @identifier).current_usage_count
  end

  test 'an expired budget starts a new fixed window' do
    freeze_time do
      AuthRateLimit.check!(action: :account_access, scope: :contact_ip, request: @request, submitted_contact: @contact)
      first_expiry = AuthRateLimitCounter.order(:id).last.expires_at
      travel 30.minutes
      AuthRateLimit.check!(action: :account_access, scope: :contact_ip, request: @request, submitted_contact: @contact)
      assert_equal first_expiry, AuthRateLimitCounter.order(:id).last.expires_at

      travel 31.minutes
      AuthRateLimit.check!(action: :account_access, scope: :contact_ip, request: @request, submitted_contact: @contact)
      assert_equal 1, AuthRateLimitCounter.order(:id).last.attempts
    end
  end

  test 'registration recipient budgets span ips and normalized variants' do
    3.times do |index|
      AuthRateLimit.check!(action: :registration, scope: :contact, submitted_contact: @contact,
                           request: Struct.new(:remote_ip).new("203.0.113.#{index}"))
    end
    assert_raises(AuthRateLimit::ExceededError) do
      AuthRateLimit.check!(action: :registration, scope: :contact, submitted_contact: @contact.upcase)
    end
  end

  test 'account and contact consumers have safe defaults without policy rows' do
    Policy.where(key: Policy::RATE_LIMIT_KEYS).delete_all
    assert_equal({ max: 30, period: 1.hour }, AuthRateLimit.limit_config_for(:registration, :ip))
    assert_equal({ max: 3, period: 1.hour }, AuthRateLimit.limit_config_for(:registration, :contact))
    assert_equal({ max: 10, period: 1.hour }, AuthRateLimit.limit_config_for(:sms_verification, :contact))
    assert_equal({ max: 5, period: 1.hour }, AuthRateLimit.limit_config_for(:contact_change, :user_ip))
  end

  test 'invalid policy max uses the centralized safe default' do
    Policy.find_by!(key: 'account_access_rate_limit_contact_ip').update_column(:value, 0)
    assert_equal AuthRateLimit.default_max(:account_access, :contact_ip),
                 AuthRateLimit.limit_config_for(:account_access, :contact_ip)[:max]
  end

  test 'unknown scopes and raw identifiers are refused' do
    assert_nil AuthRateLimit.limit_config_for(:registration, :unknown)
    assert_raises(ArgumentError) { AuthRateLimit.check!(action: :registration, scope: :unknown) }
    assert_raises(ArgumentError) { AuthRateLimit.new(action: :registration, scope: :contact, identifier: @contact) }
  end

  test 'database refusal fails closed through the public limiter error contract' do
    AuthRateLimitCounter.stub(:reserve!, ->(**) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert_raises(AuthRateLimit::UnavailableError) do
        AuthRateLimit.check!(action: :registration, scope: :contact, submitted_contact: @contact)
      end
    end
  end

  test 'policy read failure also fails closed' do
    Policy.stub(:get, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert_raises(AuthRateLimit::UnavailableError) do
        AuthRateLimit.check!(action: :registration, scope: :contact, submitted_contact: @contact)
      end
    end
  end

  test 'ip digest is keyed instead of a plain hash' do
    assert_equal 64, AuthRateLimit.request_ip_digest(@request).length
    assert_not_equal Digest::SHA256.hexdigest(@request.remote_ip), AuthRateLimit.request_ip_digest(@request)
  end

  private

  def set_policy(key, value)
    policy = Policy.find_or_initialize_by(key: key)
    if policy.persisted?
      policy.update_column(:value, value)
    else
      policy.update!(value: value)
    end
  end
end
