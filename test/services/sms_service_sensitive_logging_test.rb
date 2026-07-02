# frozen_string_literal: true

require 'test_helper'

class SmsServiceSensitiveLoggingTest < ActiveSupport::TestCase
  test 'sensitive SMS logging omits the message body and full phone number' do
    SmsService.stubs(:twilio_configured?).returns(false)

    Rails.logger.expects(:info).with do |message|
      message.include?('SMS delivery requested') &&
        message.exclude?('https://example.test/secure_provider_info_form?token=raw-token') &&
        message.exclude?('4105550199') &&
        message.include?('secure_request_form_id')
    end

    SmsService.send_message(
      '410-555-0199',
      'Submit here: https://example.test/secure_provider_info_form?token=raw-token',
      sensitive: true,
      context: { secure_request_form_id: 123, application_id: 456 }
    )
  end

  test 'sensitive SMS logging omits account access reset URLs' do
    SmsService.stubs(:twilio_configured?).returns(false)

    reset_url = 'https://example.test/password/edit?token=secret-reset-token'
    Rails.logger.expects(:info).with do |message|
      message.include?('SMS delivery requested') &&
        message.exclude?(reset_url) &&
        message.exclude?('secret-reset-token') &&
        message.include?('recipient_id')
    end

    SmsService.send_message(
      '410-555-0199',
      "MAT account access link: #{reset_url}",
      sensitive: true,
      context: { recipient_id: 42, recipient_channel: 'account_access_sms' }
    )
  end

  test 'sensitive SMS failure logging redacts account access reset URLs from provider errors' do
    reset_url = 'https://example.test/password/edit?token=secret-reset-token'
    client = mock('twilio_client')
    messages = mock('twilio_messages')

    SmsService.stubs(:twilio_configured?).returns(true)
    Twilio::REST::Client.expects(:new).returns(client)
    client.expects(:messages).returns(messages)
    messages.expects(:create).raises(StandardError.new("provider echoed #{reset_url}"))

    logs = capture_rails_logs do
      assert_raises(StandardError) do
        SmsService.send_message(
          '410-555-0199',
          "MAT account access link: #{reset_url}",
          sensitive: true,
          context: { recipient_id: 42, recipient_channel: 'account_access_sms' }
        )
      end
    end

    assert_includes logs, '[REDACTED_URL]'
    assert_not_includes logs, reset_url
    assert_not_includes logs, 'secret-reset-token'
  end
end
