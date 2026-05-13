# frozen_string_literal: true

require 'test_helper'

class SmsServiceTest < ActiveSupport::TestCase
  test 'formats ten digit phone numbers for Twilio delivery' do
    assert_equal '+15551234567', SmsService.format_phone_to_e164('555-123-4567')
  end

  test 'preserves already formatted E.164 phone numbers' do
    assert_equal '+15551234567', SmsService.format_phone_to_e164('+15551234567')
  end
end
