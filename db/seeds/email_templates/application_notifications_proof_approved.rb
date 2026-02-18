# frozen_string_literal: true

# Seed File for "application_notifications_proof_approved"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_approved', format: :text, locale: 'en') do |template|
  template.subject = 'Document Review Update'
  template.description = 'Sent when a specific piece of documentation submitted by the applicant has been approved.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    Thank you for submitting your application to %<organization_name>s. We appreciate your interest in our services and look forward to assisting you.

    ==================================================
    ✓ DOCUMENTATION APPROVED
    ==================================================

    We have reviewed and approved your %<proof_type_formatted>s documentation.

    %<all_proofs_approved_message_text>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name proof_type_formatted organization_name footer_text],
    'optional' => %w[all_proofs_approved_message_text]
  }

  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_approved (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
