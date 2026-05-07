# frozen_string_literal: true

template = EmailTemplate.find_or_initialize_by(name: 'application_notifications_proof_requested', format: :text, locale: 'es')
template.subject = 'Acción requerida: envíe su %<proof_type_formatted>s'
template.description = 'Se envía cuando el programa aún necesita un documento requerido antes de emitir un rechazo.'
template.body = <<~TEXT
  %<header_text>s

  Estimado/a %<constituent_full_name>s,

  Estamos revisando su solicitud de MAT y todavía necesitamos su %<proof_type_formatted>s antes de poder continuar con el trámite de su solicitud.

  %<default_options_text>s

  %<footer_text>s
TEXT
template.variables = {
  'required' => %w[header_text constituent_full_name proof_type_formatted default_options_text footer_text],
  'optional' => %w[organization_name secure_upload_url]
}
template.version = 1
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded application_notifications_proof_requested_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
