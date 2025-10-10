# frozen_string_literal: true

class Session < ApplicationRecord
  # associates the session with a user
  belongs_to :user

  # validate the presence and uniqueness of the session token, ip address, user_agent
  # Note: session_token uniqueness is already checked in generate_session_token callback
  validates :session_token, presence: true
  validates :ip_address, presence: true
  validates :user_agent, presence: true

  # Scopes for active and expired sessions
  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }
  scope :expired, -> { where('expires_at IS NOT NULL AND expires_at <= ?', Time.current) }

  # generate a session token before validation on create
  before_validation :generate_session_token, on: :create

  # sets the user agent and IP address before validation on create
  before_validation :set_user_agent_and_ip, on: :create

  # sets the expiration date on create
  before_create :set_expiry

  # Check if the session is expired
  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # Default session expiration period
  def self.default_expiry_period
    2.weeks
  end

  private

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
