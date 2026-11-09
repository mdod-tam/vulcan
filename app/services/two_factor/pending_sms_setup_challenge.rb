# frozen_string_literal: true

module TwoFactor
  class PendingSmsSetupChallenge
    RESEND_COOLDOWN_SECONDS = 30
    TERMINAL_STATUSES = %w[approved expired canceled max_attempts_reached not_found deleted failed].freeze
    DUPLICATE_SEND_MESSAGE = 'A verification code is being sent. Please wait a moment.'

    def self.session_phone_number(session)
      type_key = TwoFactorAuth::SESSION_KEYS[:type]
      return unless (session[type_key] || session[type_key.to_s]).to_s == 'sms_setup'

      metadata_key = TwoFactorAuth::SESSION_KEYS[:metadata]
      metadata = (session[metadata_key] || session[metadata_key.to_s] || {}).with_indifferent_access
      metadata[:phone_number]
    end

    def initialize(session:, user:, phone_number:)
      @session = session
      @user = user
      @phone_number = PhoneNumber.normalize(phone_number).to_s
    end

    def prepare!
      return false unless owner
      return :active if active_session?

      send_and_store!
    end

    def active_session?
      owner.present? && challenge_data[:type].to_s == 'sms_setup' &&
        verification_sid.present? && metadata[:owner] == owner &&
        metadata[:phone_number] == phone_number &&
        metadata[:code_expires_at].to_i > Time.current.to_i
    end

    def resend_wait_seconds
      return 0 unless active_session?

      elapsed = Time.current.to_i - metadata[:last_sent_at].to_i
      [RESEND_COOLDOWN_SECONDS - elapsed, 0].max
    end

    def resend!
      return false unless active_session?
      return :waiting if resend_wait_seconds.positive?

      send_and_store!
    end

    def check(code)
      return { success: true, status: 'expired', valid: false } unless active_session?

      TwilioVerifyService.check_verification(
        phone_number, code,
        verification_sid: verification_sid, purpose: :setup, owner: owner
      )
    end

    def clear!
      TwoFactorAuth.clear_challenge(session)
      @challenge_data = nil
      @metadata = nil
    end

    def terminal_status?(status)
      TERMINAL_STATUSES.include?(status.to_s)
    end

    private

    attr_reader :session, :user, :phone_number

    def authority
      @authority ||= (session[:factor_enrollment_authority] || {}).with_indifferent_access
    end

    def owner
      return unless authority[:user_id] == user.id && authority[:session_id].to_i.positive? &&
                    authority[:token_digest].to_s.match?(/\A[a-f0-9]{64}\z/) &&
                    authority[:security_version] == user.security_version &&
                    authority[:nonce].present? && authority[:expires_at].to_i > Time.current.to_i

      "setup:#{user.id}:#{authority[:session_id]}:#{authority[:token_digest]}:#{authority[:security_version]}:#{authority[:nonce]}"
    end

    def send_and_store!
      result = TwilioVerifyService.send_verification(
        phone_number, purpose: :setup, owner: owner, locale: user.effective_message_locale || I18n.default_locale
      )
      return :suppressed if result[:delivery_suppressed]
      return :configuration_error if result[:configuration_error]
      return false unless result[:success] && result[:verification_sid].present? &&
                          result[:code_expires_at].to_i > Time.current.to_i

      TwoFactorAuth.store_challenge(
        session, :sms_setup, result[:verification_sid],
        verification_sid: result[:verification_sid], owner: owner, phone_number: phone_number,
        last_sent_at: Time.current.to_i,
        code_expires_at: [result[:code_expires_at].to_i, authority[:expires_at].to_i].min
      )
      @challenge_data = nil
      @metadata = nil
      Rails.logger.info("[SMS] Sent setup verification code to user #{user.id} via Twilio Verify")
      :sent
    end

    def verification_sid
      challenge_data[:challenge].presence
    end

    def challenge_data
      @challenge_data ||= TwoFactorAuth.retrieve_challenge(session)
    end

    def metadata
      @metadata ||= (challenge_data[:metadata] || {}).with_indifferent_access
    end
  end
end
