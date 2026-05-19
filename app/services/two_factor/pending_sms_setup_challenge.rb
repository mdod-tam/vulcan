# frozen_string_literal: true

module TwoFactor
  class PendingSmsSetupChallenge
    TTL = 10.minutes
    LOCK_TTL = 30.seconds
    RESEND_COOLDOWN_SECONDS = 30
    TERMINAL_STATUSES = %w[approved expired max_attempts_reached not_found].freeze
    DUPLICATE_SEND_MESSAGE = 'A verification code is being sent. Please wait a moment.'

    def self.normalize_phone(phone_number)
      digits = phone_number.to_s.gsub(/\D/, '')
      digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
      return digits.gsub(/(\d{3})(\d{3})(\d{4})/, '\1-\2-\3') if digits.length == 10

      phone_number.to_s
    end

    def self.cache_key(user_id, phone_number)
      "two_factor:pending_sms_setup:#{user_id}:#{normalize_phone(phone_number)}"
    end

    def self.lock_key(user_id, phone_number)
      "#{cache_key(user_id, phone_number)}:lock"
    end

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
      @phone_number = self.class.normalize_phone(phone_number)
    end

    def prepare!
      return :active if active_session?

      return :active if hydrate_from_cache! && active_session?
      return :sending unless acquire_lock

      begin
        return :active if hydrate_from_cache! && active_session?

        send_and_store! ? :sent : false
      ensure
        release_lock
      end
    end

    def active_session?
      challenge_data[:type].to_s == 'sms_setup' &&
        verification_sid.present? &&
        metadata[:phone_number] == phone_number &&
        unexpired?(metadata)
    end

    def resend_wait_seconds
      return 0 unless active_session?

      elapsed_seconds = Time.current.to_i - metadata[:last_sent_at].to_i
      [RESEND_COOLDOWN_SECONDS - elapsed_seconds, 0].max
    end

    def resend!
      return false unless active_session?
      return :waiting if resend_wait_seconds.positive?
      return :sending unless acquire_lock

      begin
        return false unless active_session?
        return :waiting if resend_wait_seconds.positive?

        send_and_store! ? :sent : false
      ensure
        release_lock
      end
    end

    def check(code)
      return { success: true, status: 'expired', valid: false } unless active_session?

      TwilioVerifyService.check_verification(
        phone_number,
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

    attr_reader :session, :user, :phone_number

    def hydrate_from_cache!
      cached_metadata = cached_active_metadata
      return false unless cached_metadata

      store_challenge(cached_metadata[:verification_sid], cached_metadata)
      true
    end

    def acquire_lock
      Rails.cache.write(lock_key, true, expires_in: LOCK_TTL, unless_exist: true)
    end

    def cached_active_metadata
      cached_metadata = (Rails.cache.read(cache_key) || {}).with_indifferent_access
      return if cached_metadata.blank?
      return if cached_metadata[:verification_sid].blank?
      return unless unexpired?(cached_metadata)

      cached_metadata
    end

    def store_result!(result)
      new_metadata = metadata_from_result(result)
      store_challenge(result[:verification_sid], new_metadata)
      Rails.cache.write(cache_key, new_metadata, expires_in: TTL)
    end

    def store_challenge(challenge, challenge_metadata)
      TwoFactorAuth.store_challenge(session, :sms_setup, challenge, challenge_metadata)
      @challenge_data = nil
      @metadata = nil
    end

    def metadata_from_result(result)
      {
        verification_sid: result[:verification_sid],
        phone_number: phone_number,
        last_sent_at: Time.current.to_i,
        code_expires_at: TTL.from_now.to_i
      }
    end

    def verification_sid
      challenge_data[:challenge].presence
    end

    def unexpired?(source_metadata)
      expires_at = source_metadata[:code_expires_at].to_i
      expires_at.positive? && expires_at > Time.current.to_i
    end

    def cache_key
      self.class.cache_key(user.id, phone_number)
    end

    def lock_key
      self.class.lock_key(user.id, phone_number)
    end

    def release_lock
      Rails.cache.delete(lock_key)
    end

    def send_and_store!
      result = TwilioVerifyService.send_verification(phone_number)
      return false unless result[:success] && result[:verification_sid].present?

      store_result!(result)
      Rails.logger.info("[SMS] Sent setup verification code to user #{user.id} via Twilio Verify")
      true
    end

    def challenge_data
      @challenge_data ||= TwoFactorAuth.retrieve_challenge(session)
    end

    def metadata
      @metadata ||= (challenge_data[:metadata] || {}).with_indifferent_access
    end
  end
end
