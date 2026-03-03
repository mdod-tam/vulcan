# frozen_string_literal: true

# Seed File for "application_notifications_proof_rejected"
# (Suggest saving as db/seeds/email_templates/application_notifications_proof_rejected.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_rejected', format: :text, locale: 'es') do |template|
  template.subject = 'Actualización de Revisión de Documentos'
  template.description = 'Enviado cuando se ha rechazado un documento específico enviado por el solicitante.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<constituent_full_name>s,

    Hemos revisado su documentación de %<proof_type_formatted>s y ha sido rechazada.

    MOTIVO DEL RECHAZO: %<rejection_reason>s
    %<additional_instructions>s

    %<remaining_attempts_message_text>s

    %<default_options_text>s

    %<archived_message_text>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name proof_type_formatted rejection_reason footer_text],
    'optional' => %w[organization_name remaining_attempts_message_text additional_instructions default_options_text archived_message_text]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_rejected_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
