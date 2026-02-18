# frozen_string_literal: true

# Seed File for "application_notifications_proof_received"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_received', format: :text, locale: 'en') do |template|
  template.subject = 'Document Received'
  template.description = 'Sent when a piece of documentation submitted by the applicant has been received and is awaiting review.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    Thank you for submitting your application to %<organization_name>s. We appreciate your interest in our services and look forward to assisting you.

    ==================================================
    ✓ DOCUMENTATION RECEIVED
    ==================================================

    We have received your %<proof_type_formatted>s documentation and it is now under review.

    We will notify you once our review is complete. Thank you for your patience.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name organization_name proof_type_formatted footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_received (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
