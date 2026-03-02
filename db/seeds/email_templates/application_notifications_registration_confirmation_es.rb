# frozen_string_literal: true

# Seed File for "application_notifications_registration_confirmation"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_registration_confirmation', format: :text, locale: 'es') do |template|
  template.subject = 'Bienvenido/a al Programa de Telecomunicaciones Accesibles de Maryland'
  template.description = 'Sent to a user immediately after they register an account, outlining program and next steps.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_full_name>s,

    Gracias por registrarse en Telecomunicaciones Accesibles de Maryland. Ayudamos a los residentes de Maryland con dificultades para usar un teléfono estándar a comprar productos de telecomunicaciones que satisfagan sus necesidades.

    == RESUMEN DEL PROGRAMA ==

    Nuestro programa proporciona vales a los residentes elegibles de Maryland que se pueden utilizar para comprar productos de telecomunicaciones accesibles.

    == PRÓXIMOS PASOS ==

    Para solicitar asistencia:

    1. Inicie una nueva solicitud.
    2. Proporcione toda la información requerida, incluyendo prueba de residencia e información de contacto de un profesional que pueda certificar su estado de discapacidad.
    3. Envíe su solicitud para su revisión.

    Una vez que su solicitud sea aprobada, recibirá un vale con un valor fijo que se puede utilizar para comprar productos elegibles, junto con información sobre qué productos son elegibles y qué proveedores están autorizados para aceptar los vales.

    Una variedad de productos para una variedad de discapacidades son elegibles para la compra con un vale, incluyendo:

    * Teléfonos inteligentes (iPhone, iPad, Pixel) con características y aplicaciones de accesibilidad para apoyar múltiples tipos de discapacidades
    * Teléfonos amplificados para personas con pérdida auditiva
    * Teléfonos fijos especializados para personas con pérdida de visión o pérdida auditiva
    * Productos de braille y voz para personas con diferencias en el habla
    * Ayudas de comunicación para diferencias cognitivas, de memoria o de habla
    * Sistemas y accesorios de alerta visual, audible y táctil

    == MINORISTAS AUTORIZADOS ==

    Puede canjear su vale en cualquiera de estos proveedores autorizados:
    %<active_vendors_text_list>s

    Una vez que su solicitud sea aprobada, recibirá un vale para comprar productos elegibles a través de estos proveedores.

    Si tiene alguna pregunta sobre nuestro programa o necesita ayuda con su solicitud, no dude en contactarnos a %<support_email>s o al 410-697-9700.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_full_name active_vendors_text_list footer_text support_email],
    'optional' => %w[dashboard_url new_application_url]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_registration_confirmation_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
