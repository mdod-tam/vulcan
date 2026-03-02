# frozen_string_literal: true

# Seed File for "application_notifications_proof_submission_error"
# (Suggest saving as db/seeds/email_templates/application_notifications_proof_submission_error.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_submission_error', format: :text, locale: 'en') do |template|
  template.subject = 'Error Processing Your Proof Submission'
  template.description = 'Sent to the user when an error occurs during the automated processing of a proof submitted via email.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<constituent_full_name>s,

    We encountered an issue while processing your recent proof submission via email.

    ERROR: %<message>s

    Please review the error message above and try again.

    If you need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

    Thank you for your understanding.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name message footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_submission_error (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
