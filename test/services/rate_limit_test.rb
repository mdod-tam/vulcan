# frozen_string_literal: true

require 'test_helper'

class RateLimitTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @action = :proof_submission
    @method = :email
    @identifier = 'user@example.com'
    @limit = 5
    @period_hours = 24

    Policy.find_or_create_by(key: "#{@action}_rate_limit_#{@method}") do |policy|
      policy.value = @limit
    end

    Policy.find_or_create_by(key: "#{@action}_rate_period") do |policy|
      policy.value = @period_hours
    end

    # The records can already exist with other values.
    limit_policy = Policy.find_by(key: "#{@action}_rate_limit_#{@method}")
    period_policy = Policy.find_by(key: "#{@action}_rate_period")

    limit_policy.update_column(:value, @limit) if limit_policy&.value != @limit
    period_policy.update_column(:value, @period_hours) if period_policy&.value != @period_hours

    assert_equal @limit, Policy.get("#{@action}_rate_limit_#{@method}")
    assert_equal @period_hours, Policy.get("#{@action}_rate_period")

    Policy.stubs(:rate_limit_for).with(@action, @method).returns({
                                                                   max: @limit,
                                                                   period: @period_hours.hours
                                                                 })

    # Used by the "limit is per-action and per-method" test.
    Policy.stubs(:rate_limit_for).with(:different_action, @method).returns({
                                                                             max: @limit,
                                                                             period: @period_hours.hours
                                                                           })

    Policy.stubs(:rate_limit_for).with(@action, :web).returns({
                                                                max: @limit,
                                                                period: @period_hours.hours
                                                              })

    Rails.cache.unstub(:read)
    Rails.cache.unstub(:increment)
    Rails.cache.unstub(:clear)

    @test_cache = {}

    Rails.cache.stubs(:increment).returns do |key, value = 1, options = {}|
      if key.to_s.include?('rate_limit:')
        @test_cache[key] ||= 0
        @test_cache[key] += value

        @test_cache["#{key}:expires_at"] = Time.current + options[:expires_in] if options && options[:expires_in]

        @test_cache[key]
      else
        1
      end
    end

    Rails.cache.stubs(:read).returns do |key, _options = nil|
      if key.to_s.include?('rate_limit:')
        expiry_key = "#{key}:expires_at"
        if @test_cache.key?(expiry_key) && Time.current > @test_cache[expiry_key]
          @test_cache.delete(key)
          @test_cache.delete(expiry_key)
          nil
        else
          @test_cache[key]
        end
      else
        nil
      end
    end

    Rails.cache.stubs(:clear).returns { @test_cache.clear }
  end

  teardown do
    travel_back
    Rails.cache.clear
  end

  test 'first check passes and increments counter' do
    cache_key = "rate_limit:#{@action}:#{@method}:#{@identifier}"
    Rails.cache.expects(:increment).with(cache_key, 1, has_entry(expires_in: @period_hours.hours)).returns(1)

    assert_nothing_raised do
      RateLimit.check!(@action, @identifier, @method)
    end
  end

  test 'subsequent checks within limit pass and increment counter' do
    # The first test covers the counter increment.
    @limit.times do |_i|
      assert_nothing_raised do
        RateLimit.check!(@action, @identifier, @method)
      end
    end
  end

  test 'exceeding limit raises RateLimit::ExceededError' do
    RateLimit.any_instance.stubs(:current_usage_count).returns(@limit)

    error = assert_raises(RateLimit::ExceededError) do
      RateLimit.check!(@action, @identifier, @method)
    end

    assert_match(/rate limit exceeded for #{@action}/i, error.message)
    assert_match(/\(#{@method}\)/i, error.message)
    assert_match(/maximum #{@limit} submissions/i, error.message)
    assert_match(/per #{@period_hours} hour/i, error.message)
  end

  test 'limit resets after period expires' do
    RateLimit.any_instance.stubs(:current_usage_count).returns(@limit)

    assert_raises(RateLimit::ExceededError) do
      RateLimit.check!(@action, @identifier, @method)
    end

    travel_to Time.current + @period_hours.hours + 1.minute

    # Simulates an expired counter.
    RateLimit.any_instance.stubs(:current_usage_count).returns(0)

    assert_nothing_raised do
      RateLimit.check!(@action, @identifier, @method)
    end
  end

  test 'limit is per-action and per-method' do
    @limit.times do
      RateLimit.check!(@action, @identifier, @method)
    end

    assert_nothing_raised do
      RateLimit.check!(:different_action, @identifier, @method)
    end

    assert_nothing_raised do
      RateLimit.check!(@action, @identifier, :web)
    end

    assert_nothing_raised do
      RateLimit.check!(@action, 'different_user@example.com', @method)
    end
  end

  test 'raises ArgumentError for unknown action' do
    # Policy returns nil when it has no rate limit configuration.
    Policy.stubs(:rate_limit_for).with(:unknown_action, anything).returns(nil)

    assert_raises(ArgumentError, 'Unknown rate limit action') do
      RateLimit.check!(:unknown_action, @identifier, @method)
    end
  end
end
