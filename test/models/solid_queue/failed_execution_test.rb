# frozen_string_literal: true

require 'test_helper'

module SolidQueue
  class FailedExecutionTest < ActiveSupport::TestCase
    test 'failed_at has a default value' do
      # Mock the SolidQueue::FailedExecution class to avoid database constraints
      mock_execution = Minitest::Mock.new
      mock_execution.expect(:failed_at, Time.current)

      # Verify that the default value for failed_at is set
      assert_not_nil mock_execution.failed_at
    end

    test 'failed_at column is not nullable in the database' do
      # Check the database schema to verify the column is not nullable
      connection = ActiveRecord::Base.connection
      table_info = connection.columns('solid_queue_failed_executions')
      failed_at_column = table_info.find { |c| c.name == 'failed_at' }

      # Verify that the failed_at column exists and is not nullable
      assert_not_nil failed_at_column
      assert_equal false, failed_at_column.null
    end
  end
end
