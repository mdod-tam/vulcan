# frozen_string_literal: true

# Concern for handling user authentication, password management, and session tracking.
module UserAuthentication
  extend ActiveSupport::Concern

  # Constants
  MAX_LOGIN_ATTEMPTS = 5
  PASSWORD_RESET_EXPIRY = 20.minutes
  LOCK_DURATION = 1.hour

  included do
    # Define the password accessors first. Rails' has_secure_password installs its own
    # password-salt token definition, so our stronger password-plus-email definition
    # must be registered afterward.
    has_secure_password

    # Token generation for password reset. Bound to a fingerprint of both the password
    # digest and the normalized login email (not the digest alone) so either a password
    # change OR a login-email change -- e.g. a merge reassigning the login email to a
    # different survivor -- invalidates outstanding tokens. This is a distinct mechanism from
    # clearing the legacy reset_password_token/reset_password_sent_at columns on retirement;
    # the two must not be conflated.
    generates_token_for :password_reset, expires_in: 20.minutes do
      password_reset_token_fingerprint
    end

    # Associations
    has_many :sessions, dependent: :destroy

    # Two-Factor Authentication Associations
    has_many :webauthn_credentials, dependent: :destroy
    has_many :totp_credentials, dependent: :destroy
    has_many :sms_credentials, dependent: :destroy

    # Validations
    validates :password, length: { minimum: 8 }, if: -> { password.present? }
    validates :reset_password_token, uniqueness: true, allow_nil: true
  end

  # Class methods
  class_methods do
    def digest(string)
      cost = ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
      BCrypt::Password.create(string, cost: cost)
    end
  end

  # Authentication methods
  def account_locked?
    return false if locked_at.blank?
    return true if locked_at > LOCK_DURATION.ago

    unlock_account!
    false
  end

  def record_failed_login!
    next_attempt_count = failed_attempts.to_i + 1

    # Failed login counters are auth bookkeeping and should not be blocked by
    # unrelated legacy profile validations.
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

    # Sign-in tracking should not be blocked by unrelated legacy profile validations.
    # No auth state transition callbacks depend on these audit columns, and updated_at
    # is maintained explicitly here.
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

  # Password reset methods
  def generate_password_reset_token!
    update(
      reset_password_token: SecureRandom.urlsafe_base64,
      reset_password_sent_at: Time.current
    )
  end

  # Check if any second factor is enabled
  def second_factor_enabled?
    webauthn_credentials.exists? ||
      totp_credentials.exists? ||
      sms_credentials.verified.exists?
  end

  private

  # HMAC-SHA256 of the password digest (standing in for a dedicated password salt column,
  # which this schema does not have) plus the normalized login email. Used only as the
  # generates_token_for :password_reset payload above -- see that block's comment.
  def password_reset_token_fingerprint
    OpenSSL::HMAC.hexdigest('SHA256', password_digest.to_s, User.normalize_email(email).to_s)
  end
end
