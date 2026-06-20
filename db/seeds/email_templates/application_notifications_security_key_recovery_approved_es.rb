# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_security_key_recovery_approved', format: :text, locale: 'es') do |template|
  template.subject = 'Recuperación de Llave de Seguridad Aprobada'
  template.description = 'Enviado cuando un administrador aprueba una solicitud de recuperación de llave de seguridad.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    Su solicitud de recuperación de llave de seguridad ha sido aprobada. Sus llaves de seguridad existentes se han eliminado de su cuenta.

    Inicie sesión y registre una nueva llave de seguridad.

    Enlace de inicio de sesión:
    %<sign_in_url>s

    Si tiene preguntas o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name sign_in_url support_email footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_security_key_recovery_approved_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
