# frozen_string_literal: true

require 'test_helper'

class RecordSecureFormExpirationsJobTest < ActiveJob::TestCase
  test 'delegates to the secure form expiration recorder' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    SecureFormExpirationRecorder.any_instance.expects(:call).returns(result)

    RecordSecureFormExpirationsJob.perform_now
  end

  test 'raises when the recorder fails' do
    result = BaseService::Result.new(success: false, message: 'boom', data: {})
    SecureFormExpirationRecorder.any_instance.expects(:call).returns(result)

    assert_raises(StandardError) { RecordSecureFormExpirationsJob.perform_now }
  end
end
