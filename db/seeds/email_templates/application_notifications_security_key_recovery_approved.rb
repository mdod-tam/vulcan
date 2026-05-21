# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_security_key_recovery_approved', format: :text, locale: 'en') do |template|
  template.subject = 'Security Key Recovery Approved'
  template.description = 'Sent when an administrator approves a security key recovery request.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    Your security key recovery request has been approved. Your existing security keys have been removed from your account.

    Please sign in and register a new security key: %<sign_in_url>s

    If you have questions or need assistance, please contact our team at %<support_email>s.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name sign_in_url support_email footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_security_key_recovery_approved (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
