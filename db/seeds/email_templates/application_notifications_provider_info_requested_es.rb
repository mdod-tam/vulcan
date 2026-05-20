# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_provider_info_requested', format: :text, locale: 'es') do |template|
  template.subject = 'Se Necesita Información del Profesional Certificador'
  template.description = 'Enviado cuando MAT solicita información de contacto del profesional certificador mediante un formulario seguro.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    El Programa de Telecomunicaciones Accesibles de Maryland necesita información de contacto del profesional certificador relacionado con la solicitud de %<constituent_name>s.

    %<provider_info_instructions>s

    Necesitamos el nombre, número de teléfono, correo electrónico y número de fax del profesional, si está disponible. No responda con registros médicos u otros documentos sensibles.

    Si tiene preguntas, comuníquese con nuestro equipo de soporte en %<support_email>s.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name constituent_name provider_info_instructions support_email footer_text],
    'optional' => %w[secure_url expiration_hours application_id support_phone]
  }
  template.version = 1
end

Rails.logger.debug 'Seeded application_notifications_provider_info_requested_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
