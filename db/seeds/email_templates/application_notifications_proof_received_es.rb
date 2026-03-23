# frozen_string_literal: true

# Seed File for "application_notifications_proof_received"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_received', format: :text, locale: 'es') do |template|
  template.subject = 'Documento Recibido'
  template.description = 'Enviado cuando se ha recibido un documento enviado por el solicitante y está esperando revisión.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    Hemos recibido su documentación de %<proof_type_formatted>s y ahora está en revisión.

    Le notificaremos una vez que nuestra revisión esté completa. Gracias por su paciencia.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name proof_type_formatted footer_text],
    'optional' => %w[organization_name]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_received_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
