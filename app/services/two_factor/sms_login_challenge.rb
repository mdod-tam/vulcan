# frozen_string_literal: true

module TwoFactor
  class SmsLoginChallenge
    RESEND_COOLDOWN_SECONDS = 30
    TERMINAL_STATUSES = %w[approved expired canceled max_attempts_reached not_found deleted failed].freeze

    def initialize(session:, credential:)
      @session = session
      @credential = credential
    end

    def ensure_for!(user)
      return false unless user.id == credential.user_id && active_two_factor_user?
      return :active if active?

      send_and_store!(user)
    end

    def resend_for!(user)
      return false unless user.id == credential.user_id && active_two_factor_user?
      return :waiting if resend_wait_seconds.positive?

      send_and_store!(user)
    end

    def active?
      active_two_factor_user? && challenge_data[:type].to_s == 'sms' &&
        verification_sid.present? && metadata[:owner] == owner &&
        metadata[:phone_number] == credential.phone_number &&
        metadata[:credential_id].to_s == credential.id.to_s &&
        metadata[:code_expires_at].to_i > Time.current.to_i
    end

    def resend_wait_seconds
      return 0 unless active?

      elapsed = Time.current.to_i - metadata[:last_sent_at].to_i
      [RESEND_COOLDOWN_SECONDS - elapsed, 0].max
    end

    def check(code)
      return { success: true, status: 'expired', valid: false } unless active?

      TwilioVerifyService.check_verification(
        credential.phone_number, code,
        verification_sid: verification_sid, purpose: :login, owner: owner
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

    attr_reader :session, :credential

    def send_and_store!(user)
      result = TwilioVerifyService.send_verification(
        credential.phone_number,
        purpose: :login, owner: owner, sms_credential_id: credential.id,
        locale: I18n.locale
      )
      return :suppressed if result[:delivery_suppressed]
      return :configuration_error if result[:configuration_error]
      return false unless result[:success] && result[:verification_sid].present? &&
                          result[:code_expires_at].to_i > Time.current.to_i

      TwoFactorAuth.store_challenge(
        session, :sms, result[:verification_sid],
        verification_sid: result[:verification_sid], owner: owner, credential_id: credential.id,
        phone_number: credential.phone_number, last_sent_at: Time.current.to_i,
        code_expires_at: result[:code_expires_at].to_i
      )
      @challenge_data = nil
      @metadata = nil
      Rails.logger.info("[SMS] Sent verification code to user #{user.id} via Twilio Verify")
      :sent
    end

    def owner
      nonce = session[TwoFactorAuth::SESSION_KEYS[:sms_owner]]
      return if nonce.blank?

      "login:#{credential.user_id}:#{nonce}"
    end

    def active_two_factor_user?
      owner.present? && session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]].to_s == credential.user_id.to_s
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
