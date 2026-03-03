# frozen_string_literal: true

# Seed File for "application_notifications_medical_certification_not_provided"
EmailTemplate.create_or_find_by!(name: 'application_notifications_medical_certification_not_provided', format: :text, locale: 'es') do |template|
  template.subject = 'Se Requiere Certificación de Discapacidad Para Su Solicitud'
  template.description = 'Enviado a un constituyente cuando envía una solicitud sin proporcionar certificación de ' \
                         'discapacidad o información de contacto del proveedor, o cuando se ha rechazado una ' \
                         'certificación enviada.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    Gracias por enviar su solicitud al Programa de Telecomunicaciones Accesibles de Maryland. Hemos recibido su envío y estamos comenzando nuestro proceso de revisión.

    Sin embargo, notamos que a su solicitud le falta la información de certificación de discapacidad. Para completar su solicitud, necesitamos documentación de un profesional calificado que confirme su discapacidad.

    PRÓXIMOS PASOS:

    1. Envíe un correo electrónico a nuestro equipo a mat.program1@maryland.gov.
    2. Proporcione una de las siguientes opciones:
       - Información de contacto de un proveedor calificado (nombre, correo electrónico, teléfono, fax), O
       - Suba un formulario de certificación de discapacidad completado

    3. Nuestro equipo se comunicará entonces con su proveedor médico para solicitar la certificación necesaria.

    QUÉ SE NECESITA:

    Requerimos un formulario de certificación de discapacidad completado por un profesional calificado (médico, psiquiatra, psicólogo, trabajador social u otro proveedor calificado) que pueda confirmar que usted tiene una discapacidad que le dificulta usar un teléfono estándar.

    %<rejection_reason_message>s

    Si tiene preguntas sobre qué documentación se necesita o necesita ayuda, comuníquese con nuestro equipo de soporte.

    ID de Solicitud: %<application_id>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name application_id footer_text],
    'optional' => %w[rejection_reason_message]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_medical_certification_not_provided_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
