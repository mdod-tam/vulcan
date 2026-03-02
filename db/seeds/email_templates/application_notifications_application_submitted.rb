# frozen_string_literal: true

# Seed File for "application_notifications_application_submitted"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_application_submitted', format: :text) do |template|
  template.subject = 'Your Application Has Been Submitted'
  template.description = 'Sent when an application is submitted.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    Thank you for submitting your application to Maryland Accessible Telecommunications. We have received your submission and will review your application as soon as possible.

    Application ID: %<application_id>s
    Submission Date: %<submission_date_formatted>s

    You can track the status of your application at any time by logging into your account. We will send you updates as we progress through the review process.

    If you need to submit additional documentation or have any questions about your application, please log into your account or contact our support team.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name application_id submission_date_formatted footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_application_submitted (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
