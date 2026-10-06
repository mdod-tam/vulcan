# frozen_string_literal: true

# Password, lockout, sign-in tracking, password reset, and second-factor state for User.
module UserAuthentication
  extend ActiveSupport::Concern

  # Maryland's external-user authentication guidance requires at least 12 characters. Forms read this
  # for their minlength and hint, so the browser and the server state the same rule.
  PASSWORD_MIN_LENGTH = 12
  MAX_LOGIN_ATTEMPTS = 5
  LOCK_DURATION = 1.hour

  included do
    # has_secure_password defines its own :password_reset token from the password salt.
    # Register the stronger definition below after it, so that ours replaces it.
    has_secure_password

    # The token binds to the password digest and to each route that can receive a reset link:
    # the login email and the phone. A change to any of them revokes links already sent.
    # The phone is necessary because SMS also delivers reset links. For example, a duplicate merge
    # that replaces a phone must revoke the link sent to the discarded number.
    # This is separate from clearing the legacy reset_password_token and reset_password_sent_at
    # columns on retirement. Do not combine the two mechanisms.
    generates_token_for :password_reset, expires_in: 20.minutes do
      password_reset_token_fingerprint
    end

    has_many :sessions, dependent: :destroy

    has_many :webauthn_credentials, dependent: :destroy
    has_many :totp_credentials, dependent: :destroy
    has_many :sms_credentials, dependent: :destroy

    validates :password, length: { minimum: PASSWORD_MIN_LENGTH }, if: -> { password.present? }
    validates :reset_password_token, uniqueness: true, allow_nil: true
  end

  class_methods do
    def digest(string)
      cost = ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
      BCrypt::Password.create(string, cost: cost)
    end
  end

  def account_locked?
    return false if locked_at.blank?
    return true if locked_at > LOCK_DURATION.ago

    unlock_account!
    false
  end

  def record_failed_login!
    next_attempt_count = failed_attempts.to_i + 1

    # Skip validations so that invalid legacy profile data cannot block the failed-login count.
    # rubocop:disable Rails/SkipsModelValidations
    update_columns(
      failed_attempts: next_attempt_count,
      updated_at: Time.current
    )
    # rubocop:enable Rails/SkipsModelValidations

    lock_account! if next_attempt_count >= MAX_LOGIN_ATTEMPTS
  end

  def track_sign_in!(ip)
    if failed_attempts.to_i >= MAX_LOGIN_ATTEMPTS
      lock_account!
      return false
    end

    # Skip validations so that invalid legacy profile data cannot block sign-in tracking.
    # No callbacks depend on these columns. This code sets updated_at itself.
    # rubocop:disable Rails/SkipsModelValidations
    update_columns(
      last_sign_in_at: Time.current,
      last_sign_in_ip: ip,
      failed_attempts: 0,
      locked_at: nil,
      updated_at: Time.current
    )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def lock_account!
    update!(locked_at: Time.current)
  end

  def unlock_account!
    # rubocop:disable Rails/SkipsModelValidations
    update_columns(
      failed_attempts: 0,
      locked_at: nil,
      updated_at: Time.current
    )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def second_factor_enabled?
    webauthn_credentials.exists? ||
      totp_credentials.exists? ||
      sms_credentials.verified.exists?
  end

  private

  # Payload for the :password_reset token above. The password digest is the HMAC key
  # because the schema has no separate password salt column.
  # The lookup normalizers make sure that a format-only change does not revoke the token.
  # The separator prevents collisions between different email and phone splits.
  def password_reset_token_fingerprint
    contact_authority = [
      User.normalize_email(email).to_s,
      User.normalize_phone(phone).to_s
    ].join("\x1f")

    OpenSSL::HMAC.hexdigest('SHA256', password_digest.to_s, contact_authority)
  end
end
