# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_account_created', format: :text, locale: 'es') do |template|
  template.subject = 'Recibimos su solicitud de Telecomunicaciones Accesibles de Maryland'
  template.description = 'Enviado cuando se recibe una solicitud y se crea una cuenta de constituyente.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<constituent_first_name>s,

    Hemos recibido su solicitud de equipos y servicios de telecomunicaciones accesibles.

    Le enviaremos actualizaciones importantes y documentos sobre el estado de su solicitud mientras la revisamos.

    Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    Sitio web del programa: %<program_website_url>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_first_name support_email program_website_url footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_account_created_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
