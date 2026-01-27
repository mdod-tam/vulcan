# frozen_string_literal: true

# Constants and helpers for standardized 2FA session keys
module TwoFactorAuth
  # Session keys used across different 2FA methods
  SESSION_KEYS = {
    # Existing authentication keys
    challenge: :two_factor_challenge,
    type: :two_factor_type,
    metadata: :two_factor_metadata,
    verified_at: :two_factor_verified_at,

    # Authentication flow keys
    temp_user_id: :two_factor_user_id,
    available_methods: :two_factor_available_methods,
    return_path: :two_factor_return_path
  }.freeze

  # Error messages used across different 2FA methods
  ERROR_MESSAGES = {
    invalid_code: 'Invalid verification code. Please try again.',
    expired_code: 'Verification code has expired. Please request a new one.',
    missing_credential: 'No credential found for verification.',
    webauthn_challenge_mismatch: 'Security verification failed. Please try again.',
    verification_service_unavailable: "We're experiencing temporary issues verifying codes. Please try again.",
    max_attempts_reached: 'Maximum attempts reached. Please request a new code.'
  }.freeze

  # helper methods for session management
  def self.store_temp_user_id(session, user_id)
    session[SESSION_KEYS[:temp_user_id]] = user_id
    Rails.logger.info("[2FA] Stored temporary user ID for 2FA: #{user_id}")
  end

  def self.get_temp_user_id(session)
    session[SESSION_KEYS[:temp_user_id]]
  end

  def self.store_return_path(session, path)
    session[SESSION_KEYS[:return_path]] = path if path.present?
  end

  def self.get_return_path(session)
    session[SESSION_KEYS[:return_path]]
  end

  def self.store_challenge(session, type, challenge, metadata = {})
    session[SESSION_KEYS[:type]] = type
    session[SESSION_KEYS[:challenge]] = challenge
    session[SESSION_KEYS[:metadata]] = metadata
    Rails.logger.info("[2FA] Stored #{type} challenge in session")
    challenge
  end

  def self.retrieve_challenge(session)
    {
      type: session[SESSION_KEYS[:type]],
      challenge: session[SESSION_KEYS[:challenge]],
      metadata: session[SESSION_KEYS[:metadata]]
    }
  end

  def self.clear_challenge(session)
    session.delete(SESSION_KEYS[:type])
    session.delete(SESSION_KEYS[:challenge])
    session.delete(SESSION_KEYS[:metadata])
  end

  def self.mark_verified(session)
    session[SESSION_KEYS[:verified_at]] = Time.current.to_i
    Rails.logger.info('[2FA] Session marked as verified')
  end

  def self.complete_authentication(session)
    session.delete(SESSION_KEYS[:temp_user_id])
    session.delete(SESSION_KEYS[:available_methods])
    session.delete(SESSION_KEYS[:return_path])
    # NOTE: Challenge is NOT cleared here - it should be cleared after successful sign_in
    mark_verified(session)
    Rails.logger.info('[2FA] Authentication completed and session marked as verified (challenge preserved)')
  end

  def self.complete_authentication_with_challenge_clear(session)
    complete_authentication(session)
    clear_challenge(session)
    Rails.logger.info('[2FA] Challenge cleared after successful sign-in')
  end

  def self.verified?(session)
    verified_at = session[SESSION_KEYS[:verified_at]]
    return false unless verified_at

    # You could add expiry logic here if needed
    # return false if verified_at < 24.hours.ago.to_i

    true
  end

  # Updated to accept optional context hash
  def self.log_verification_success(user_id, type, context = {})
    log_message = "[2FA] Successful verification for user #{user_id} with #{type}"
    log_message += " (Credential ID: #{context[:credential_id]})" if context[:credential_id]
    Rails.logger.info(log_message)
  end

  # Updated to accept optional context hash
  def self.log_verification_failure(user_id, type, error, context = {})
    log_message = "[2FA] Failed verification for user #{user_id} with #{type}: #{error}"
    log_message += " (Credential ID: #{context[:credential_id]})" if context[:credential_id]
    log_message += " (Attempted Credential IDs: #{context[:credential_ids]})" if context[:credential_ids]
    Rails.logger.warn(log_message) # Use warn level for failures
  end
end
