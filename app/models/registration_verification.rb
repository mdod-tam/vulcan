# frozen_string_literal: true

class RegistrationVerification < ApplicationRecord
  LIFETIME = 60.minutes
  TOKEN_PURPOSE = :registration_email
  EMAIL_MAX_LENGTH = 254

  encrypts :email
  belongs_to :created_user, class_name: 'User', optional: true
  has_many :email_delivery_attempts, as: :origin, dependent: :nullify

  before_validation :normalize_email, on: :create
  validates :email, presence: true, length: { maximum: EMAIL_MAX_LENGTH }
  validates :locale, inclusion: { in: %w[en es] }
  validates :expires_at, presence: true
  validates :delivery_status, inclusion: { in: %w[pending queued submitted not_sent failed] }
  validate :email_is_real
  validate :issued_authority_is_immutable, on: :update
  validate :consumption_cannot_be_reversed, on: :update

  def self.resolve(token)
    find_signed(token, purpose: TOKEN_PURPOSE)&.then { |row| row if row.active? }
  end

  def active?(now = Time.current)
    consumed_at.nil? && expires_at > now
  end

  def proof_token
    signed_id(purpose: TOKEN_PURPOSE, expires_at: expires_at)
  end

  private

  def normalize_email
    self.email = User.normalize_email(email)
  end

  def email_is_real
    errors.add(:email, :invalid) unless User.real_email_address?(email)
  end

  def consumption_cannot_be_reversed
    errors.add(:consumed_at, :invalid) if consumed_at_in_database.present? && will_save_change_to_consumed_at?
    errors.add(:created_user_id, :invalid) if created_user_id_in_database.present? && will_save_change_to_created_user_id?
  end

  def issued_authority_is_immutable
    return unless will_save_change_to_email? || will_save_change_to_expires_at? || will_save_change_to_locale?

    errors.add(:base, :invalid)
  end
end
