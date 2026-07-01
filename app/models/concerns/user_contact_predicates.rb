# frozen_string_literal: true

# Canonical contact truth predicates for portal eligibility, auth guards, and display.
module UserContactPredicates
  extend ActiveSupport::Concern

  def real_email?
    return false if email.blank?
    return false unless email.to_s.match?(URI::MailTo::EMAIL_REGEXP)
    return false if User.system_generated_email?(email)

    true
  end

  def real_phone?
    return false if phone.blank?
    return false if User.synthetic_dependent_phone?(phone)

    digits = phone.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    digits.length == 10
  end

  def sms_capable_phone?
    real_phone? && phone_type == 'text'
  end

  def portal_access_eligible?
    real_email? || real_phone?
  end

  # PR3 public portal self-service: user-facing portal accounts require stored real email.
  def email_backed_portal_account?
    real_email?
  end

  def mfa_account_name
    return email if real_email?

    return phone if real_phone?

    name = full_name.presence
    return name if name.present?

    "user-#{id || 'new'}"
  end

  def portal_phone_only_without_email?
    email.blank? && real_phone?
  end

  def address_only_contact?
    !real_email? && !real_phone?
  end
end
