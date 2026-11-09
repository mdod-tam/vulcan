# frozen_string_literal: true

# Provider I/O stays outside the durable reservation's transaction. Each SID
# belongs to one local purpose and browser owner until it completes or expires.
class TwilioVerifyService
  ACTIONS = { login: 'TwoFactor#sms_login', setup: 'TwoFactor#sms_setup',
              reauthentication: 'TwoFactor#sms_reauthentication', contact_change: 'ContactChange#sms_verification' }.freeze
  TERMINAL_STATUSES = %w[expired canceled max_attempts_reached deleted failed].freeze

  class << self
    def send_verification(phone_number, purpose:, owner:, locale: 'en', sms_credential_id: nil)
      action = ACTIONS.fetch(purpose.to_sym)
      context = EmailDelivery::Policy.capture(mail_action: action,
                                              params: { sms_credential_id: sms_credential_id, phone_number: phone_number })
      EmailDelivery.verify!(action, context: context, channel: 'sms')
      return refused unless test_mode? || verify_configured?

      provider_lifetime = configured_provider_lifetime
      attempt, version = SmsVerificationAttempt.reserve_send!(
        service_sid: reservation_service_sid, phone: phone_number, purpose: purpose, owner: owner, provider_lifetime: provider_lifetime
      )
      return attempt.provider_result unless version

      EmailDelivery.verify!(action, context: context, channel: 'sms')
      verification = if test_mode?
                       { sid: "TEST_#{SecureRandom.hex(8)}", to: format_phone_to_e164(phone_number), channel: 'sms',
                         service_sid: reservation_service_sid, date_created: Time.current }
                     else
                       provider_service.verifications.create(channel: 'sms', to: format_phone_to_e164(phone_number),
                                                             locale: supported_locale(locale))
                     end
      sid = read_twilio_attribute(verification, :sid)
      created_at = read_twilio_attribute(verification, :date_created)
      return refused unless sid.present? && created_at.respond_to?(:acts_like_time?) && created_at.acts_like_time? &&
                            provider_identity_matches?(verification, sid: sid, phone: phone_number)

      attempt.finish_send!(version: version, sid: sid, provider_created_at: created_at, provider_lifetime: provider_lifetime)
      EmailDelivery::Outcome.record_essential_handoff(context: context, channel: :sms)
      attempt.provider_result
    rescue ApplicationMailer::DeliverySkipped, EmailDelivery::ConfigurationError => e
      { success: false, delivery_suppressed: e.is_a?(ApplicationMailer::DeliverySkipped),
        configuration_error: e.is_a?(EmailDelivery::ConfigurationError), reason: e.reason,
        error: I18n.t(e.is_a?(ApplicationMailer::DeliverySkipped) ? 'outbound_delivery.sms_suppressed' : 'outbound_delivery.sms_configuration_error') }
    rescue SmsVerificationAttempt::Refused, AuthRateLimit::ExceededError
      refused
    rescue StandardError => e
      Rails.logger.warn("SMS verification send failed: #{e.class.name}")
      refused
    end

    def check_verification(phone_number, code, verification_sid:, purpose:, owner:)
      return refused unless code.is_a?(String) && code.match?(/\A[0-9]{6}\z/)
      return refused unless test_mode? || verify_configured?

      attempt, version = SmsVerificationAttempt.reserve_check!(
        service_sid: reservation_service_sid, phone: phone_number, purpose: purpose, owner: owner, verification_sid: verification_sid
      )
      begin
        checked = provider_check(phone_number, code, verification_sid)
      rescue Twilio::REST::RestError => e
        attempt.finish_check!(version: version, approved: false, terminal: terminal_provider_error?(e))
        return refused
      end
      matches = provider_identity_matches?(checked, sid: verification_sid, phone: phone_number)
      status = read_twilio_attribute(checked, :status).to_s
      approved = matches && status == 'approved'
      attempt.finish_check!(version: version, approved: approved, terminal: !matches || TERMINAL_STATUSES.include?(status))
      { success: matches, status: matches ? status : 'failed', valid: approved,
        receipt_id: (attempt.id if approved), to: format_phone_to_e164(phone_number) }
    rescue SmsVerificationAttempt::Refused, ActiveRecord::RecordNotFound, AuthRateLimit::ExceededError
      refused
    rescue StandardError => e
      Rails.logger.warn("SMS verification check failed: #{e.class.name}")
      refused
    end

    private

    def configured_provider_lifetime
      seconds = Integer(Rails.application.config.twilio.fetch(:verify_token_lifetime_seconds, 600))
      raise ArgumentError, 'Unsupported Verify token lifetime' unless seconds.between?(120, 86_400)

      seconds.seconds
    end

    def provider_check(phone, code, sid)
      return provider_service.verification_checks.create(verification_sid: sid, code: code) unless test_mode?

      { sid: sid, service_sid: reservation_service_sid, to: format_phone_to_e164(phone),
        channel: 'sms', status: code == '123456' ? 'approved' : 'pending' }
    end

    def terminal_provider_error?(error)
      error.code.in?([60_202, 60_203]) || read_twilio_attribute(error, :status_code) == 404
    end

    def provider_identity_matches?(result, sid:, phone:)
      read_twilio_attribute(result, :sid) == sid &&
        read_twilio_attribute(result, :service_sid) == reservation_service_sid &&
        PhoneNumber.normalize(read_twilio_attribute(result, :to)) == PhoneNumber.normalize(phone) &&
        read_twilio_attribute(result, :channel) == 'sms'
    end

    def refused
      { success: false, status: 'unavailable', valid: false, error: I18n.t('contact_changes.verification_unavailable') }
    end

    def client
      @client ||= Twilio::REST::Client.new(
        Rails.application.config.twilio[:account_sid], Rails.application.config.twilio[:auth_token]
      ).tap { |instance| instance.http_client = Twilio::HTTP::Client.new(timeout: 15) }
    end

    def provider_service
      client.verify.v2.services(verify_service_sid)
    end

    def verify_service_sid
      Rails.application.config.twilio[:verify_service_sid]
    end

    def reservation_service_sid
      verify_service_sid.presence || 'TEST_VERIFY_SERVICE'
    end

    def verify_configured?
      config = Rails.application.config.twilio
      config[:account_sid].present? && config[:auth_token].present? && config[:verify_service_sid].present?
    end

    def test_mode?
      Rails.env.test? || (Rails.env.development? && !verify_configured?)
    end

    def supported_locale(locale)
      %w[en es].include?(locale.to_s) ? locale.to_s : 'en'
    end

    def format_phone_to_e164(phone)
      return phone if phone.start_with?('+')

      digits = phone.gsub(/\D/, '')
      digits = "1#{digits}" if digits.length == 10
      "+#{digits}"
    end

    def read_twilio_attribute(object, *names)
      names.each do |name|
        return object.public_send(name) if object.respond_to?(name)
        return object[name] if object.respond_to?(:key?) && object.key?(name)
        return object[name.to_s] if object.respond_to?(:key?) && object.key?(name.to_s)
      end
      nil
    end
  end
end
