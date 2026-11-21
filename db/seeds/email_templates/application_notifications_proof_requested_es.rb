# frozen_string_literal: true

template = EmailTemplate.find_or_initialize_by(name: 'application_notifications_proof_requested', format: :text, locale: 'es')
template.subject = 'Acción requerida: envíe su %<proof_type_formatted>s'
template.description = 'Se envía cuando el personal solicita un comprobante, incluida una actualización del comprobante de ingresos.'
template.body = <<~TEXT
  %<header_text>s

  Estimado/a %<constituent_full_name>s,

  %<request_explanation>s

  %<default_options_text>s

  %<footer_text>s
TEXT
template.variables = {
  'required' => %w[header_text constituent_full_name proof_type_formatted default_options_text footer_text request_explanation],
  'optional' => %w[organization_name secure_upload_url]
}
template.version = 2
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded application_notifications_proof_requested_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
