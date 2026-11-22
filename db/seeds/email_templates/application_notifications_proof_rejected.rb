# frozen_string_literal: true

template = EmailTemplate.find_or_initialize_by(name: 'application_notifications_proof_rejected', format: :text, locale: 'en')
template.subject = 'Action Needed: Please Submit a Corrected Document'
template.description = 'Sent when a specific piece of documentation submitted by the applicant has been rejected.'
template.body = <<~TEXT
  %<header_text>s

  Dear %<constituent_full_name>s,

  We reviewed your %<proof_type_formatted>s.

  %<request_explanation>s

  Reason we could not accept this document:
  %<rejection_reason>s
  %<additional_instructions>s

  %<remaining_attempts_message_text>s

  %<default_options_text>s

  %<archived_message_text>s

  %<footer_text>s
TEXT
template.variables = {
  'required' => %w[header_text constituent_full_name proof_type_formatted rejection_reason footer_text request_explanation],
  'optional' => %w[organization_name secure_upload_url remaining_attempts_message_text additional_instructions default_options_text archived_message_text]
}
template.version = 4
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded application_notifications_proof_rejected (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
