# frozen_string_literal: true

require 'test_helper'

class SmsServiceTest < ActiveSupport::TestCase
  test 'formats ten digit phone numbers for Twilio delivery' do
    assert_equal '+15551234567', SmsService.format_phone_to_e164('555-123-4567')
  end

  test 'preserves already formatted E.164 phone numbers' do
    assert_equal '+15551234567', SmsService.format_phone_to_e164('+15551234567')
  end

  test 'delivery failures preserve the exception while logging only its class' do
    private_detail = 'Private Patient private-sms@example.test at 410-555-0199 token=private-sms-token'
    error = StandardError.new(private_detail)
    error.set_backtrace(["#{private_detail}:1:in failure"])
    provider_messages = mock('provider_messages')
    provider_messages.expects(:create).raises(error)
    Twilio::REST::Client.stubs(:new).returns(stub(messages: provider_messages))
    SmsService.stubs(:twilio_configured?).returns(true)
    EmailDelivery::Policy.stubs(:capture).returns({})
    EmailDelivery.stubs(:verify!).returns(true)
    messages = []

    raised = Rails.logger.stub(:error, ->(message) { messages << message }) do
      assert_raises(StandardError) do
        SmsService.send_message('410-555-0199', private_detail, sensitive: true, action: 'SmsService#proof_resubmission')
      end
    end

    assert_same error, raised
    assert_includes messages.join, 'StandardError'
    %w[Private private-sms@example.test 410-555-0199 private-sms-token].each do |private_value|
      assert_not_includes messages.join, private_value
    end
  end
end
