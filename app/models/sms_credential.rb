# frozen_string_literal: true

class SmsCredential < ApplicationRecord
  belongs_to :user

  PHONE_REGEX = /\A\d{3}-\d{3}-\d{4}\z/ # e.g. 410-555-1234

  scope :verified, -> { where.not(verified_at: nil) }

  validates :phone_number, presence: true, format: { with: PHONE_REGEX }
  validates :phone_number, uniqueness: { scope: :user_id, message: 'is already registered' }, on: :create
  validates :last_sent_at, presence: true

  before_validation :format_phone_number
  before_validation :set_last_sent_at, on: :create

  def self.normalize_phone_number(phone_number)
    return if phone_number.blank?

    digits = phone_number.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    return digits.gsub(/(\d{3})(\d{3})(\d{4})/, '\1-\2-\3') if digits.length == 10

    phone_number
  end

  def verified?
    verified_at.present?
  end

  private

  def format_phone_number
    return if phone_number.blank?

    self.phone_number = self.class.normalize_phone_number(phone_number)
  end

  def set_last_sent_at
    self.last_sent_at ||= Time.current
  end
end
