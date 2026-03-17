# frozen_string_literal: true

class SmsCredential < ApplicationRecord
  belongs_to :user

  encrypts :code_digest

  PHONE_REGEX = /\A\d{3}-\d{3}-\d{4}\z/ # e.g. 410-555-1234

  validates :phone_number, presence: true, format: { with: PHONE_REGEX }
  validates :last_sent_at, presence: true

  before_validation :format_phone_number
  before_validation :set_last_sent_at, on: :create

  def send_code!
    # Use Twilio Verify API to send verification code
    result = TwilioVerifyService.send_verification(phone_number)

    if result[:success]
      # Update last_sent_at to track when code was sent
      # Twilio manages the code and expiration
      # We store the verification_sid for reference but don't store the code
      update!(
        last_sent_at: Time.current,
        code_expires_at: 10.minutes.from_now # Twilio's default expiration
      )
      true
    else
      Rails.logger.error("[SmsCredential] Failed to send verification: #{result[:error]}")
      false
    end
  end

  def verify_code(code)
    # Use Twilio Verify API to check verification code
    # More secure than storing codes locally
    result = TwilioVerifyService.check_verification(phone_number, code)

    if result[:success]
      # Return whether the code was valid
      result[:valid]
    else
      # If there was an error communicating with Twilio, log it and return false
      Rails.logger.error("[SmsCredential] Failed to verify code: #{result[:error]}")
      false
    end
  end

  private

  def generate_code
    SecureRandom.random_number(10**6).to_s.rjust(6, '0') # 6-digit code
  end

  def format_phone_number
    return if phone_number.blank?

    # Use the same formatting logic as in User model
    # Strip all non-digit characters
    digits = phone_number.gsub(/\D/, '')
    # Remove leading '1' if present
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    # Format as XXX-XXX-XXXX if we have 10 digits or keep original
    self.phone_number = if digits.length == 10
                          digits.gsub(/(\d{3})(\d{3})(\d{4})/, '\1-\2-\3')
                        else
                          # Keep the original input if invalid
                          phone_number
                        end
  end

  def set_last_sent_at
    self.last_sent_at ||= Time.current
  end
end
