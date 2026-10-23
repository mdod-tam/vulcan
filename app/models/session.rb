# frozen_string_literal: true

class Session < ApplicationRecord
  IDLE_TIMEOUT = 30.minutes
  ACTIVITY_WRITE_INTERVAL = 1.minute

  # associates the session with a user
  belongs_to :user

  # validate the presence and uniqueness of the session token, ip address, user_agent
  # Note: session_token uniqueness is already checked in generate_session_token callback
  validates :session_token, presence: true
  validates :ip_address, presence: true
  validates :user_agent, presence: true

  # generate a session token before validation on create
  before_validation :generate_session_token, on: :create

  # sets the user agent and IP address before validation on create
  before_validation :set_user_agent_and_ip, on: :create
  before_validation :set_initial_activity, on: :create

  # sets the expiration date on create
  before_create :set_expiry

  # Check if the session is expired
  def expired?(at: Time.current)
    expires_at.nil? || expires_at <= at || last_active_at <= at - IDLE_TIMEOUT
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

  # Default session expiration period
  def self.default_expiry_period
    24.hours
  end

  private

  def set_initial_activity
    self.last_active_at ||= Time.current
  end

  def generate_session_token
    return if session_token.present?

    loop do
      self.session_token = SecureRandom.urlsafe_base64(32)
      break unless Session.exists?(session_token: session_token)
    end
  end

  def set_user_agent_and_ip
    return if user_agent.present? && ip_address.present?

    self.user_agent = Current.user_agent
    self.ip_address = Current.ip_address
  end

  def set_expiry
    self.expires_at ||= Time.current + self.class.default_expiry_period
  end
end
