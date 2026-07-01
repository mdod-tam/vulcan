# frozen_string_literal: true

module ConstituentCommunicationLabelsHelper
  CONTACT_METHOD_LABELS = {
    'voice' => 'Call me on the phone',
    'text' => 'Text me',
    'videophone' => 'Call me using ASL (videophone)',
    'email' => 'Email me',
    'letter' => 'Send me a letter in the mail'
  }.freeze

  LANGUAGE_LABELS = {
    'es' => 'Spanish'
  }.freeze

  NO_EMAIL_ON_FILE = 'No email on file'
  NO_PHONE_ON_FILE = 'No phone on file'

  def contact_method_label(phone_type)
    CONTACT_METHOD_LABELS.fetch(phone_type.to_s, 'Not specified')
  end

  def language_label(locale)
    LANGUAGE_LABELS.fetch(locale.to_s, 'English')
  end

  def delivery_preference_label(constituent)
    preference =
      if constituent.respond_to?(:effective_communication_preference)
        constituent.effective_communication_preference
      else
        constituent.communication_preference
      end

    preference.to_s.humanize.presence || 'Not specified'
  end

  def display_contact_email(user)
    email = user.respond_to?(:effective_email) ? user.effective_email : user.email
    return NO_EMAIL_ON_FILE if email.blank?
    return NO_EMAIL_ON_FILE if User.system_generated_email?(email)

    email
  end

  def display_contact_phone(user)
    phone = user.respond_to?(:effective_phone) ? user.effective_phone : user.phone
    return NO_PHONE_ON_FILE if phone.blank?
    return NO_PHONE_ON_FILE if User.synthetic_dependent_phone?(phone)

    phone
  end

  def displayable_contact_email?(user)
    display_contact_email(user) != NO_EMAIL_ON_FILE
  end
end
