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
end
