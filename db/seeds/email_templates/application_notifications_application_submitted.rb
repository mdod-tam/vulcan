# frozen_string_literal: true

# Seed File for "application_notifications_application_submitted"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_application_submitted', format: :text, locale: 'en') do |template|
  template.subject = 'Your Application Has Been Submitted'
  template.description = 'Sent when an application is submitted.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    Thank you for submitting your application. We will review it as soon as possible.

    Application ID: %<application_id>s
    Submission Date: %<submission_date_formatted>s

    We will notify you of any status updates or if we need additional documentation.

    %<sign_in_url>s

    If you have any questions about your application, please contact our team at %<support_email>s or call (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name application_id submission_date_formatted footer_text support_email],
    'optional' => %w[sign_in_url]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_application_submitted (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
