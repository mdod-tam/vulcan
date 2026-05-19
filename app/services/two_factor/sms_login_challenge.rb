# frozen_string_literal: true

module TwoFactor
  class SmsLoginChallenge
    TTL = 10.minutes
    LOCK_TTL = 30.seconds
    RESEND_COOLDOWN_SECONDS = 30
    TERMINAL_STATUSES = %w[approved expired max_attempts_reached not_found].freeze
    DUPLICATE_SEND_MESSAGE = 'A verification code is being sent. Please wait a moment.'

    def self.cache_key(credential_id)
      "two_factor:sms_login:#{credential_id}"
    end

    def self.lock_key(credential_id)
      "#{cache_key(credential_id)}:lock"
    end

    def initialize(session:, credential:)
      @session = session
      @credential = credential
    end

    def ensure_for!(user)
      return :active if active?

      return :active if hydrate_from_cache! && active?
      return :sending unless acquire_lock

      begin
        return :active if hydrate_from_cache! && active?

        send_and_store!(user) ? :sent : false
      ensure
        release_lock
      end
    end

    def resend_for!(user)
      return false unless active_two_factor_user?
      return :waiting if resend_wait_seconds.positive?
      return :sending unless acquire_lock

      begin
        return :waiting if resend_wait_seconds.positive?

        send_and_store!(user) ? :sent : false
      ensure
        release_lock
      end
    end

    def active?
      active_two_factor_user? &&
        challenge_data[:type].to_s == 'sms' &&
        verification_sid.present? &&
        metadata[:phone_number] == credential.phone_number &&
        metadata[:credential_id].to_s == credential.id.to_s &&
        unexpired?(metadata)
    end

    def resend_wait_seconds
      source_metadata = active? ? metadata : cached_active_metadata
      return 0 unless source_metadata

      elapsed_seconds = Time.current.to_i - source_metadata[:last_sent_at].to_i
      [RESEND_COOLDOWN_SECONDS - elapsed_seconds, 0].max
    end

    def check(code)
      return { success: true, status: 'expired', valid: false } unless active?

      TwilioVerifyService.check_verification(
        credential.phone_number,
        code,
        verification_sid: verification_sid
      )
    end

    def clear!
      TwoFactorAuth.clear_challenge(session)
      Rails.cache.delete(cache_key)
      release_lock
    end

    def terminal_status?(status)
      TERMINAL_STATUSES.include?(status.to_s)
    end

    private

    attr_reader :session, :credential

    def hydrate_from_cache!
      cached_metadata = cached_active_metadata
      return false unless cached_metadata

      store_challenge(cached_metadata[:verification_sid], cached_metadata)
      true
    end

    def cached_active_metadata
      cached_metadata = (Rails.cache.read(cache_key) || {}).with_indifferent_access
      return if cached_metadata.blank?
      return if cached_metadata[:verification_sid].blank?
      return unless unexpired?(cached_metadata)

      cached_metadata
    end

    def acquire_lock
      Rails.cache.write(lock_key, true, expires_in: LOCK_TTL, unless_exist: true)
    end

    def send_and_store!(user)
      result = TwilioVerifyService.send_verification(credential.phone_number)
      return false unless result[:success] && result[:verification_sid].present?

      new_metadata = metadata_from_result(result)
      store_challenge(result[:verification_sid], new_metadata)
      Rails.cache.write(cache_key, new_metadata, expires_in: TTL)
      Rails.logger.info("[SMS] Sent verification code to user #{user.id} via Twilio Verify")
      true
    rescue StandardError => e
      Rails.logger.error("[SMS] Error: #{e.message}")
      false
    end

    def store_challenge(challenge, challenge_metadata)
      TwoFactorAuth.store_challenge(session, :sms, challenge, challenge_metadata)
      @challenge_data = nil
      @metadata = nil
    end

    def metadata_from_result(result)
      {
        verification_sid: result[:verification_sid],
        credential_id: credential.id,
        phone_number: credential.phone_number,
        last_sent_at: Time.current.to_i,
        code_expires_at: TTL.from_now.to_i
      }
    end

    def active_two_factor_user?
      session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]].to_s == credential.user_id.to_s
    end

    def verification_sid
      challenge_data[:challenge].presence
    end

    def unexpired?(source_metadata)
      expires_at = source_metadata[:code_expires_at].to_i
      expires_at.positive? && expires_at > Time.current.to_i
    end

    def challenge_data
      @challenge_data ||= TwoFactorAuth.retrieve_challenge(session)
    end

    def metadata
      @metadata ||= (challenge_data[:metadata] || {}).with_indifferent_access
    end

    def cache_key
      self.class.cache_key(credential.id)
    end

    def lock_key
      self.class.lock_key(credential.id)
    end

    def release_lock
      Rails.cache.delete(lock_key)
    end
  end
end
