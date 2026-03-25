# frozen_string_literal: true

# Seed File for "application_notifications_proof_submission_error"
# (Suggest saving as db/seeds/email_templates/application_notifications_proof_submission_error.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_submission_error', format: :text, locale: 'es') do |template|
  template.subject = 'Error al Procesar su Envío de Prueba'
  template.description = 'Enviado al usuario cuando ocurre un error durante el procesamiento automático de una prueba enviada por correo electrónico.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<constituent_full_name>s,

    Encontramos un problema al procesar su reciente envío de prueba por correo electrónico.

    ERROR: %<message>s

    Por favor revise el mensaje de error anterior y vuelva a intentarlo.

    Si necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    Gracias por su comprensión.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name message footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_submission_error_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
