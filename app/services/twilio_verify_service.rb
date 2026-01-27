# frozen_string_literal: true

# Service for interacting with Twilio Verify API for 2FA
# Twilio Verify documentation: https://www.twilio.com/docs/verify/quickstarts/ruby-rails
class TwilioVerifyService
  class << self
    # Send a verification code via SMS
    # @param phone_number [String] Phone number in E.164 format (e.g., +12025551234)
    # @return [Hash] Result with :success, :verification_sid, :status, and :error keys
    def send_verification(phone_number)
      return test_mode_success(phone_number) if test_mode?

      unless verify_configured?
        Rails.logger.warn('[TwilioVerify] Verify not configured, skipping verification send')
        return { success: false, error: 'Twilio Verify not configured' }
      end

      phone_e164 = format_phone_to_e164(phone_number)
      Rails.logger.info("[TwilioVerify] Sending verification to #{phone_e164}")

      verification = client
                     .verify
                     .v2
                     .services(verify_service_sid)
                     .verifications
                     .create(
                       channel: 'sms',
                       to: phone_e164
                     )

      Rails.logger.info("[TwilioVerify] Verification sent successfully, SID: #{verification.sid}, Status: #{verification.status}")

      {
        success: true,
        verification_sid: verification.sid,
        status: verification.status,
        to: verification.to,
        channel: verification.channel
      }
    rescue Twilio::REST::RestError => e
      Rails.logger.error("[TwilioVerify] Twilio API error: #{e.message}")
      Rails.logger.error("[TwilioVerify] Error code: #{e.code}") if e.respond_to?(:code)
      { success: false, error: e.message, error_code: e.code }
    rescue StandardError => e
      Rails.logger.error("[TwilioVerify] Unexpected error: #{e.message}")
      Rails.logger.error("[TwilioVerify] Backtrace: #{e.backtrace.first(5).join("\n")}")
      { success: false, error: e.message }
    end

    # Check a verification code
    # @param phone_number [String] Phone number that received the code
    # @param code [String] The verification code to check
    # @return [Hash] Result with :success, :status, :valid, and :error keys
    def check_verification(phone_number, code)
      return test_mode_check(code) if test_mode?

      unless verify_configured?
        Rails.logger.warn('[TwilioVerify] Verify not configured, skipping verification check')
        return { success: false, error: 'Twilio Verify not configured' }
      end

      phone_e164 = format_phone_to_e164(phone_number)
      Rails.logger.info("[TwilioVerify] Checking verification for #{phone_e164}")

      verification_check = client
                           .verify
                           .v2
                           .services(verify_service_sid)
                           .verification_checks
                           .create(
                             to: phone_e164,
                             code: code
                           )

      is_valid = verification_check.status == 'approved'
      Rails.logger.info("[TwilioVerify] Verification check result: #{verification_check.status}, Valid: #{is_valid}")

      {
        success: true,
        status: verification_check.status,
        valid: is_valid,
        to: verification_check.to
      }
    rescue Twilio::REST::RestError => e
      Rails.logger.error("[TwilioVerify] Verification check error: #{e.message}")
      Rails.logger.error("[TwilioVerify] Error code: #{e.code}") if e.respond_to?(:code)

      # Error 60200 means "No pending verifications found"
      # Error 60202 means "Max check attempts reached"
      return { success: true, status: 'expired', valid: false, error: e.message } if e.code == 60_200
      return { success: true, status: 'max_attempts_reached', valid: false, error: e.message } if e.code == 60_202

      { success: false, error: e.message, error_code: e.code }
    rescue StandardError => e
      Rails.logger.error("[TwilioVerify] Unexpected error: #{e.message}")
      { success: false, error: e.message }
    end

    private

    def client
      @client ||= Twilio::REST::Client.new(
        Rails.application.config.twilio[:account_sid],
        Rails.application.config.twilio[:auth_token]
      )
    end

    def verify_service_sid
      Rails.application.config.twilio[:verify_service_sid]
    end

    def verify_configured?
      config = Rails.application.config.twilio
      config[:account_sid].present? &&
        config[:auth_token].present? &&
        config[:verify_service_sid].present?
    end

    def test_mode?
      return true if Rails.env.test?

      Rails.env.development? && !verify_configured?
    end

    # Convert phone number from XXX-XXX-XXXX format to E.164 format (+1XXXXXXXXXX)
    # @param phone [String] Phone number in any format
    # @return [String] Phone number in E.164 format
    def format_phone_to_e164(phone)
      return phone if phone.start_with?('+')

      # Strip all non-digit characters
      digits = phone.gsub(/\D/, '')

      # Add country code if not present
      digits = "1#{digits}" if digits.length == 10

      "+#{digits}"
    end

    # Test mode methods - used when Verify is not configured or in test environment
    def test_mode_success(phone_number)
      Rails.logger.info("[TwilioVerify] TEST MODE: Simulating verification send to #{phone_number}")
      {
        success: true,
        verification_sid: "TEST_#{SecureRandom.hex(8)}",
        status: 'pending',
        to: phone_number,
        channel: 'sms'
      }
    end

    def test_mode_check(code)
      # In test mode, accept '123456' as valid code
      is_valid = code == '123456'
      Rails.logger.info("[TwilioVerify] TEST MODE: Checking code #{code}, Valid: #{is_valid}")
      {
        success: true,
        status: is_valid ? 'approved' : 'failed',
        valid: is_valid,
        to: 'test-number'
      }
    end
  end
end
