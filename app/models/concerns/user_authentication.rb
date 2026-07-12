# frozen_string_literal: true

require 'openssl'

# Concern for handling user authentication, password management, and session tracking.
module UserAuthentication
  extend ActiveSupport::Concern

  # Constants
  MAX_LOGIN_ATTEMPTS = 5
  PASSWORD_RESET_EXPIRY = 20.minutes
  LOCK_DURATION = 1.hour

  included do
    has_secure_password reset_token: { expires_in: PASSWORD_RESET_EXPIRY }

    # has_secure_password defines its own password-only fingerprint, so this must come
    # afterward. Binding the token to login identity invalidates links after an email
    # change without embedding the email itself in the human-readable token payload.
    generates_token_for :password_reset, expires_in: PASSWORD_RESET_EXPIRY do
      fingerprint = [password_salt&.last(10), User.normalize_email(email)].join("\0")
      OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, fingerprint)
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
end
