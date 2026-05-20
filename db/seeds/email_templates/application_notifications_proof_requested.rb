# frozen_string_literal: true

template = EmailTemplate.find_or_initialize_by(name: 'application_notifications_proof_requested', format: :text, locale: 'en')
template.subject = 'Action Needed: Please Submit Your %<proof_type_formatted>s'
template.description = 'Sent when the program still needs a required proof document before any rejection has been issued.'
template.body = <<~TEXT
  %<header_text>s

  Dear %<constituent_full_name>s,

  We are reviewing your MAT application and still need your %<proof_type_formatted>s before we can continue processing your application.

  %<default_options_text>s

  %<footer_text>s
TEXT
template.variables = {
  'required' => %w[header_text constituent_full_name proof_type_formatted default_options_text footer_text],
  'optional' => %w[organization_name secure_upload_url]
}
template.version = 1
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded application_notifications_proof_requested (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
