# frozen_string_literal: true

# Seed File for "application_notifications_proof_rejected"
# (Suggest saving as db/seeds/email_templates/application_notifications_proof_rejected.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_rejected', format: :text) do |template|
  template.subject = 'Document Review Update'
  template.description = 'Sent when a specific piece of documentation submitted by the applicant has been rejected.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<constituent_full_name>s,

    Thank you for submitting your application to %<organization_name>s. We appreciate your interest in our services and look forward to assisting you.

    ==================================================
    ✗ DOCUMENTATION REJECTED
    ==================================================

    We have reviewed your %<proof_type_formatted>s documentation and it has been rejected.

    ==================================================
    ℹ REASON FOR REJECTION
    ==================================================

    %<rejection_reason>s

    %<remaining_attempts_message_text>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name proof_type_formatted organization_name rejection_reason footer_text],
    'optional' => %w[remaining_attempts_message_text]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_rejected (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
