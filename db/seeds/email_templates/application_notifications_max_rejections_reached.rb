# frozen_string_literal: true

# Seed File for "application_notifications_max_rejections_reached"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_max_rejections_reached', format: :text, locale: 'en') do |template|
  template.subject = 'Important Application Status Update'
  template.description = 'Sent when an application is archived because the maximum number of document revision attempts has been reached.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    We regret to inform you that your application (ID: %<application_id>s) has been archived due to reaching the maximum number of document revision attempts.

    Your current application cannot proceed further in the review process. However, you are welcome to submit a new application after %<reapply_date_formatted>s.

    WHY APPLICATIONS ARE ARCHIVED
    Applications may be archived when we are unable to verify eligibility after multiple attempts. This is typically due to:
    * Missing or incomplete documentation
    * Inability to verify residency

    FUTURE APPLICATIONS
    When submitting a new application after %<reapply_date_formatted>s, please ensure you have the following ready:
    * Current proof of Maryland residency
    * Any disability documentation required for the program

    If you have any questions about this decision or need assistance with a future application, please contact our team at %<support_email>s or call (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name application_id reapply_date_formatted footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_max_rejections_reached (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
