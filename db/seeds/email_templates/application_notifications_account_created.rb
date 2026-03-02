# frozen_string_literal: true

# Seed File for "application_notifications_account_created"
# Took out the login details as they are not needed for the account creation notification for the internal release.
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_account_created', format: :text, locale: 'en') do |template|
  template.subject = 'Your Maryland Accessible Telecommunications Account'
  template.description = 'Sent when an application is received and a constituent account is created, providing initial login details.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<constituent_first_name>s,

    We have received your application for accessible telecommunications equipment and services.

    We will to send you important updates and documents regarding your application status as we review it.

    If you have any questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_first_name footer_text support_email],
    'optional' => %w[constituent_email temp_password sign_in_url]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_account_created (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
