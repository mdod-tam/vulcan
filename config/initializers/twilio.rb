# frozen_string_literal: true

# Twilio Configuration
Rails.application.config.twilio = {
  account_sid: ENV.fetch('TWILIO_ACCOUNT_SID', nil),
  auth_token: ENV.fetch('TWILIO_AUTH_TOKEN', nil),
  sms_from_number: ENV.fetch('TWILIO_SMS_FROM_NUMBER', nil), # Legacy - still needed for non-Verify SMS
  verify_service_sid: ENV.fetch('TWILIO_VERIFY_SERVICE_SID', nil) # For 2FA verification
}
