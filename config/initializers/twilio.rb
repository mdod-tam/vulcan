# frozen_string_literal: true

Rails.application.config.twilio = {
  account_sid: ENV.fetch('TWILIO_ACCOUNT_SID', nil),
  auth_token: ENV.fetch('TWILIO_AUTH_TOKEN', nil),
  fax_from_number: ENV.fetch('TWILIO_FAX_FROM_NUMBER', nil),
  sms_from_number: ENV.fetch('TWILIO_SMS_FROM_NUMBER', nil),
  verify_service_sid: ENV.fetch('TWILIO_VERIFY_SERVICE_SID', nil) # For 2FA verification
}
