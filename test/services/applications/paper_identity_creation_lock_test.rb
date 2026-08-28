# frozen_string_literal: true

require 'test_helper'

module Applications
  class PaperIdentityCreationLockTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'refuses to acquire a transaction-scoped lock without an open transaction' do
      connection = ActiveRecord::Base.connection
      assert_not connection.transaction_open?

      error = assert_raises ArgumentError do
        PaperIdentityCreationLock.lock!(identity_facts)
      end

      assert_equal PaperIdentityCreationLock::TRANSACTION_REQUIRED_MESSAGE, error.message
      assert_not connection.transaction_open?
    end

    test 'acquires the lock for the caller open transaction' do
      connection = ActiveRecord::Base.connection

      result = ActiveRecord::Base.transaction do
        assert connection.transaction_open?
        PaperIdentityCreationLock.lock!(identity_facts)
      end

      assert_instance_of ActiveRecord::Result, result
      assert_not connection.transaction_open?
    end

    private

    def identity_facts
      { first_name: 'Lock', last_name: 'Subject', date_of_birth: Date.new(1980, 1, 15) }
    end
  end
end
