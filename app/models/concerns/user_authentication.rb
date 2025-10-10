# frozen_string_literal: true

# Concern for handling user authentication, password management, and session tracking.
module UserAuthentication
  extend ActiveSupport::Concern

  # Constants
  MAX_LOGIN_ATTEMPTS = 5
  PASSWORD_RESET_EXPIRY = 20.minutes
  LOCK_DURATION = 1.hour

  included do
    # Token generation for email verification and password reset
    generates_token_for :password_reset, expires_in: 20.minutes
    generates_token_for :email_verification, expires_in: 1.day

    has_secure_password

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
  def track_sign_in!(ip)
    if failed_attempts.to_i >= MAX_LOGIN_ATTEMPTS
      lock_account!
      return false
    end

    update_columns(
      last_sign_in_at: Time.current,
      last_sign_in_ip: ip,
      failed_attempts: 0,
      locked_at: nil,
      updated_at: Time.current
    )
  end

  def lock_account!
    update!(locked_at: Time.current)
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
      sms_credentials.exists?
  end
end
