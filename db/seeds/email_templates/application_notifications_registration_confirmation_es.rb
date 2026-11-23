# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_registration_confirmation', format: :text, locale: 'es') do |template|
  template.subject = 'Bienvenido/a al Programa de Telecomunicaciones Accesibles de Maryland'
  template.description = 'Enviado a un usuario inmediatamente después de registrar una cuenta, describiendo el programa y los próximos pasos.'
  template.body = <<~TEXT
    %<header_text>s

    Hola, %<user_full_name>s,

    Su cuenta de MAT está lista. Inicie sesión para comenzar su solicitud.

    Tenga a mano su identificación con foto, un comprobante de su domicilio en Maryland y los datos de contacto de su profesional certificador. MAT también puede pedirle un comprobante de los ingresos del hogar.

    Si necesita ayuda, escriba a %<support_email>s o llame al 410-697-9700.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_full_name footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_registration_confirmation_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
