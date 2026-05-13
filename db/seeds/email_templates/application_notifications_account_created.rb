# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_account_created', format: :text, locale: 'en') do |template|
  template.subject = 'We Received Your Maryland Accessible Telecommunications Application'
  template.description = 'Sent when an application is received and a constituent account is created.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<constituent_first_name>s,

    We have received your application for accessible telecommunications equipment and services.

    We will send you important updates and documents regarding your application status as we review it.

    If you have any questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

    Program website: %<program_website_url>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_first_name support_email program_website_url footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_account_created (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
