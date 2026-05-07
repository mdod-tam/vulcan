# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_provider_info_requested', format: :text, locale: 'en') do |template|
  template.subject = 'Certifying Professional Information Needed'
  template.description = 'Sent when MAT requests certifying professional contact information through a secure request form.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    The Maryland Accessible Telecommunications Program needs contact information for the certifying professional connected to %<constituent_name>s's application.

    %<provider_info_instructions>s

    We need the professional's name, phone number, email address, and fax number if available. Do not reply with medical records or other sensitive documents.

    If you have questions, contact our support team at %<support_email>s.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name constituent_name provider_info_instructions support_email footer_text],
    'optional' => %w[secure_url expiration_hours application_id support_phone]
  }
  template.version = 1
end

Rails.logger.debug 'Seeded application_notifications_provider_info_requested (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
