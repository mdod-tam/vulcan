# frozen_string_literal: true

require 'active_support/core_ext/securerandom'

class Session < ApplicationRecord
  class AuthenticationRequired < StandardError; end

  IDLE_TIMEOUT = 30.minutes
  ACTIVITY_WRITE_INTERVAL = 1.minute
  REAUTHENTICATION_WINDOW = 5.minutes

  belongs_to :user

  # The raw token is available to its issuer only; stored sessions retain its digest.
  attr_reader :session_token

  validates :session_token_digest, presence: true
  validates :ip_address, presence: true
  validates :user_agent, presence: true

  before_validation :generate_session_token, :set_initial_activity, on: :create

  before_create :set_expiry

  scope :for_token, ->(token) { where(session_token_digest: digest_token(token)) }

  scope :expired_at, lambda { |at|
    where('expires_at IS NULL OR expires_at <= :at OR last_active_at <= :idle', at: at, idle: at - IDLE_TIMEOUT)
  }

  def self.digest_token(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def session_token=(token)
    @session_token = token
    self.session_token_digest = token.present? ? self.class.digest_token(token) : nil
  end

  def expired?(at: Time.current)
    expires_at.nil? || expires_at <= at || last_active_at <= at - IDLE_TIMEOUT
  end

  # Call while holding the user's canonical lock, before any protected write. The
  # original bearer matters: a request loaded before rotation must not inherit it.
  def require_live!(token:, user:)
    raise AuthenticationRequired unless persisted? && token.present?

    reload(lock: true)
    valid_token = ActiveSupport::SecurityUtils.secure_compare(session_token_digest, self.class.digest_token(token))
    raise AuthenticationRequired unless user_id == user.id && valid_token && !expired? && user.public_login_active?

    self
  rescue ActiveRecord::RecordNotFound
    raise AuthenticationRequired
  end

  def require_recent_authentication!(token:, user:)
    require_live!(token: token, user: user)
    raise AuthenticationRequired unless freshly_authenticated?(user: user)

    self
  end

  # This predicate describes the loaded snapshot; protected writes also need the
  # live bearer check above under the user lock.
  def freshly_authenticated?(user:)
    reauthenticated_at.present? && reauthenticated_at > REAUTHENTICATION_WINDOW.ago &&
      reauthenticated_at <= Time.current && reauthenticated_security_version == user.security_version
  end

  def rotate_after_authentication!(user:)
    self.session_token = self.class.generate_unique_secure_token(length: 44)
    update!(reauthenticated_at: Time.current, reauthenticated_security_version: user.security_version,
            last_active_at: Time.current)
    self
  end

  def activity_deadlines
    {
      idle_expires_at: (last_active_at + IDLE_TIMEOUT).iso8601,
      absolute_expires_at: expires_at.iso8601,
      issued_at: Time.current.iso8601(6)
    }
  end

  # Recheck under the row lock before refreshing an older timestamp. A stale request
  # must not revive an expired session or move activity backwards.
  def record_activity!
    at = Time.current
    return false if expired?(at:)
    return true if last_active_at > at - ACTIVITY_WRITE_INTERVAL

    with_lock do
      at = Time.current
      if expired?(at:)
        false
      else
        update!(last_active_at: at) if last_active_at <= at - ACTIVITY_WRITE_INTERVAL
        true
      end
    end
  rescue ActiveRecord::RecordNotFound
    false
  end

  def self.default_expiry_period
    24.hours
  end

  private

  def generate_session_token
    self.session_token = self.class.generate_unique_secure_token(length: 44) if session_token.blank?
  end

  def set_initial_activity
    self.last_active_at ||= Time.current
  end

  def set_expiry
    self.expires_at ||= Time.current + self.class.default_expiry_period
  end
end
