# frozen_string_literal: true

# Twilio Verify adapter for SMS 2FA.
# Twilio Verify documentation: https://www.twilio.com/docs/verify/quickstarts/ruby-rails
class TwilioVerifyService
  extend SecureErrorSanitizer

  class << self
    # Sends a verification code through the SMS delivery policy.
    # @param phone_number [String] Phone number. Unprefixed ten-digit US numbers receive +1 (e.g., +12025551234)
    # @return [Hash] :success plus :verification_sid/:status on success or :error on failure
    def send_verification(phone_number, purpose:, sms_credential_id: nil)
      action = { login: 'TwoFactor#sms_login', setup: 'TwoFactor#sms_setup' }.fetch(purpose)
      context = EmailDelivery::Policy.capture(mail_action: action, params: { sms_credential_id: sms_credential_id, phone_number: phone_number })
      EmailDelivery.verify!(action, context: context, channel: 'sms')
      if test_mode?
        EmailDelivery::Outcome.record_essential_handoff(context: context, channel: :sms)
        return test_mode_success(phone_number)
      end

      unless verify_configured?
        Rails.logger.warn('[TwilioVerify] Verify not configured, skipping verification send')
        return { success: false, error: 'Twilio Verify not configured' }
      end

      phone_e164 = format_phone_to_e164(phone_number)
      Rails.logger.info("[TwilioVerify] Sending verification to #{sanitize_secure_error_message(phone_e164)}")

      EmailDelivery.verify!(action, context: context, channel: 'sms')
      verification = client
                     .verify
                     .v2
                     .services(verify_service_sid)
                     .verifications
                     .create(
                       channel: 'sms',
                       to: phone_e164
                     )

      EmailDelivery::Outcome.record_essential_handoff(context: context, channel: :sms)
      Rails.logger.info("[TwilioVerify] Verification sent successfully, SID: #{verification.sid}, Status: #{verification.status}")

      {
        success: true,
        verification_sid: verification.sid,
        status: verification.status,
        to: verification.to,
        channel: verification.channel
      }
    rescue ApplicationMailer::DeliverySkipped, EmailDelivery::ConfigurationError => e
      { success: false, delivery_suppressed: e.is_a?(ApplicationMailer::DeliverySkipped),
        configuration_error: e.is_a?(EmailDelivery::ConfigurationError), reason: e.reason,
        error: I18n.t(e.is_a?(ApplicationMailer::DeliverySkipped) ? 'outbound_delivery.sms_suppressed' : 'outbound_delivery.sms_configuration_error') }
    rescue Twilio::REST::RestError => e
      error_message = sanitize_secure_error_message(e.message)
      Rails.logger.error("[TwilioVerify] Twilio API error: #{error_message}")
      Rails.logger.error("[TwilioVerify] Error code: #{e.code}") if e.respond_to?(:code)
      { success: false, error: error_message, error_code: e.code }
    rescue StandardError => e
      error_message = sanitize_secure_error_message(e.message)
      Rails.logger.error("[TwilioVerify] Unexpected error: #{error_message}")
      Rails.logger.error("[TwilioVerify] Backtrace: #{sanitize_secure_error_message(e.backtrace.first(5).join("\n"))}") if e.backtrace.present?
      { success: false, error: error_message }
    end

    # Verifies a code against the supplied verification SID.
    # @param phone_number [String] Phone number that received the code
    # @param code [String] The verification code to check
    # @return [Hash] :success, with :status/:valid for handled checks. :error can accompany :success true or false.
    def check_verification(phone_number, code, verification_sid:)
      return test_mode_check(code) if test_mode?

      unless verify_configured?
        Rails.logger.warn('[TwilioVerify] Verify not configured, skipping verification check')
        return { success: false, error: 'Twilio Verify not configured' }
      end
      if verification_sid.blank?
        Rails.logger.warn('[TwilioVerify] Verification SID is required for verification checks')
        return { success: true, status: 'invalid_input', valid: false, error: 'Verification SID is required' }
      end

      phone_e164 = format_phone_to_e164(phone_number)
      Rails.logger.info("[TwilioVerify] Checking verification for SID #{verification_sid} and phone #{sanitize_secure_error_message(phone_e164)}")

      verification_check = client
                           .verify
                           .v2
                           .services(verify_service_sid)
                           .verification_checks
                           .create(**verification_check_params(code, verification_sid: verification_sid))

      is_valid = verification_check.status == 'approved'
      Rails.logger.info("[TwilioVerify] Verification check result: #{verification_check.status}, Valid: #{is_valid}")

      {
        success: true,
        status: verification_check.status,
        valid: is_valid,
        to: verification_check.to
      }
    rescue Twilio::REST::RestError => e
      error_message = sanitize_secure_error_message(e.message)
      Rails.logger.error("[TwilioVerify] Verification check error: #{error_message}")
      Rails.logger.error("[TwilioVerify] Error code: #{e.code}") if e.respond_to?(:code)

      # Twilio uses 60200 for invalid parameters and 60202 for exhausted code-check attempts.
      return { success: true, status: 'invalid_input', valid: false, error: error_message } if e.code == 60_200
      return { success: true, status: 'max_attempts_reached', valid: false, error: error_message } if e.code == 60_202
      return { success: true, status: 'not_found', valid: false, error: error_message } if read_twilio_attribute(e, :status_code) == 404

      { success: false, error: error_message, error_code: e.code }
    rescue StandardError => e
      error_message = sanitize_secure_error_message(e.message)
      Rails.logger.error("[TwilioVerify] Unexpected error: #{error_message}")
      { success: false, error: error_message }
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

    # Adds +1 to a ten-digit US number. Leaves input with a leading + unchanged.
    # @param phone [String] Phone number with separators, a country code, or a leading +
    # @return [String] Number with a leading +, without format validation
    def format_phone_to_e164(phone)
      return phone if phone.start_with?('+')

      digits = phone.gsub(/\D/, '')

      digits = "1#{digits}" if digits.length == 10

      "+#{digits}"
    end

    def verification_check_params(code, verification_sid:)
      { verification_sid: verification_sid, code: code }
    end

    def read_twilio_attribute(object, *names)
      names.each do |name|
        return object.public_send(name) if object.respond_to?(name)
        return object[name] if object.respond_to?(:key?) && object.key?(name)

        string_name = name.to_s
        return object[string_name] if object.respond_to?(:key?) && object.key?(string_name)
      end

      nil
    end

    # Test mode applies in tests and in development without Verify configuration.
    def test_mode_success(phone_number)
      Rails.logger.info("[TwilioVerify] TEST MODE: Simulating verification send to #{sanitize_secure_error_message(phone_number)}")
      {
        success: true,
        verification_sid: "TEST_#{SecureRandom.hex(8)}",
        status: 'pending',
        to: phone_number,
        channel: 'sms'
      }
    end

    def test_mode_check(code)
      is_valid = code == '123456'
      Rails.logger.info("[TwilioVerify] TEST MODE: Verification check valid: #{is_valid}")
      {
        success: true,
        status: is_valid ? 'approved' : 'failed',
        valid: is_valid,
        to: 'test-number'
      }
    end
  end
end
