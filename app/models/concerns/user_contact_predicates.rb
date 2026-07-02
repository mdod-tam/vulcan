# frozen_string_literal: true

# Canonical contact truth predicates for portal eligibility, auth guards, and display.
#
# Three concepts (do not collapse):
# - Record truth: real_email?, real_phone?, phone_type, portal_access_eligible?, address_only_contact?
# - Login identity (public portal only): email_backed_public_portal_account? — requires real_email?;
#   phone-only records may be portal_access_eligible? but are NOT public login-capable
# - Delivery route: sms_capable_phone? — SMS delivery, not login eligibility
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

  # Paper/admin portal-contact eligibility: real stored contact (email or phone).
  # Phone-only records qualify here but are not public portal self-service/login-capable.
  def portal_access_eligible?
    real_email? || real_phone?
  end

  # Public portal login identity: sign-in, account access, WebAuthn recovery, self-registration.
  def email_backed_public_portal_account?
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
