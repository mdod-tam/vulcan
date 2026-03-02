# frozen_string_literal: true

# Seed File for "application_notifications_proof_needs_review_reminder"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_needs_review_reminder', format: :text, locale: 'en') do |template|
  template.subject = 'Applications Awaiting Review'
  template.description = 'Sent to administrators summarizing applications that have been awaiting review for too long (e.g., > 3 days).'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<admin_full_name>s,

    ==================================================
    ! ATTENTION REQUIRED
    ==================================================

    There are %<stale_reviews_count>s applications that have been awaiting document review for more than 3 days.

    APPLICATIONS REQUIRING ATTENTION
    %<stale_reviews_text_list>s

    Please review these applications as soon as possible to ensure timely processing for our applicants.

    You can access the admin dashboard to review all pending applications at:
    %<admin_dashboard_url>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text admin_full_name stale_reviews_count stale_reviews_text_list
                     admin_dashboard_url footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_needs_review_reminder (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
