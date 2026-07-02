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
end
