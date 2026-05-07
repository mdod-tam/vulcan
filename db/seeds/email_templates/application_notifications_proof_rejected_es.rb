# frozen_string_literal: true

# Seed File for "application_notifications_proof_rejected"
# (Suggest saving as db/seeds/email_templates/application_notifications_proof_rejected.rb)
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'application_notifications_proof_rejected', format: :text, locale: 'es')
template.subject = 'Acción requerida: envíe un documento corregido'
template.description = 'Enviado cuando se ha rechazado un documento específico enviado por el solicitante.'
template.body = <<~TEXT
  %<header_text>s

  Estimado/a %<constituent_full_name>s,

  Gracias por enviar su %<proof_type_formatted>s para su solicitud de MAT. La revisamos y necesitamos una copia corregida antes de poder continuar con el trámite de su solicitud.

  Motivo por el que no pudimos aceptar este documento:
  %<rejection_reason>s
  %<additional_instructions>s

  %<remaining_attempts_message_text>s

  %<default_options_text>s

  %<archived_message_text>s

  %<footer_text>s
TEXT
template.variables = {
  'required' => %w[header_text constituent_full_name proof_type_formatted rejection_reason footer_text],
  'optional' => %w[organization_name secure_upload_url remaining_attempts_message_text additional_instructions default_options_text archived_message_text]
}
template.version = 3
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded application_notifications_proof_rejected_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
