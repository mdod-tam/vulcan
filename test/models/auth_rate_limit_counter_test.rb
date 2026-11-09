# frozen_string_literal: true

require 'test_helper'

class AuthRateLimitCounterTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ConcurrencyTestHelper

  setup do
    @key = "counter-concurrency:#{SecureRandom.hex(16)}"
  end

  teardown do
    AuthRateLimitCounter.where(key: @key).delete_all
  end

  test 'simultaneous first reservations each consume separate capacity' do
    ready = Queue.new
    start = Queue.new
    counts = Queue.new
    workers = Array.new(6) do
      Thread.new do
        ready << true
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          counts << AuthRateLimitCounter.reserve!(key: @key, period: 1.hour)
        end
      rescue StandardError => e
        counts << e
      end
    end
    6.times { ready.pop }
    6.times { start << true }
    workers.each(&:join)
    observed = Array.new(6) { counts.pop }

    assert observed.all?(Integer), observed.inspect
    assert_equal (1..6).to_a, observed.sort
    assert_equal 1, AuthRateLimitCounter.where(key: @key).count
    assert_equal 6, AuthRateLimitCounter.find_by!(key: @key).attempts
  end
end
