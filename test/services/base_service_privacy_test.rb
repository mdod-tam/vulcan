# frozen_string_literal: true

require 'test_helper'

class BaseServicePrivacyTest < ActiveSupport::TestCase
  class FailureProbe < BaseService
    def call(error, context)
      log_error(error, context)
      failure(errors.last)
    end
  end

  test 'shared diagnostic logging omits personal exception text without changing returned errors' do
    invalid_record = User.new
    private_detail = 'Private Patient private-service@example.test at 410-555-0199 token=private-service-token'
    invalid_record.errors.add(:base, private_detail)
    error = ActiveRecord::RecordInvalid.new(invalid_record)
    error.set_backtrace(["#{private_detail}:1:in failure"])

    [nil, 'Processing application 42', { application_id: 42 }].each do |context|
      messages = []
      service = FailureProbe.new
      result = Rails.logger.stub(:error, ->(message) { messages << message }) { service.call(error, context) }

      assert_not result.success?
      assert_equal error.message, result.message
      assert_equal [error.message], service.errors
      assert_includes messages.join, 'ActiveRecord::RecordInvalid'
      %w[Private private-service@example.test 410-555-0199 private-service-token].each do |private_value|
        assert_not_includes messages.join, private_value
      end
    end
  end
end
