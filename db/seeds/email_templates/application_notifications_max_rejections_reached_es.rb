# frozen_string_literal: true

# Seed File for "application_notifications_max_rejections_reached"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_max_rejections_reached', format: :text, locale: 'es') do |template|
  template.subject = 'Actualización Importante del Estado de su Solicitud'
  template.description = 'Sent when an application is archived because the maximum number of document revision attempts has been reached.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    Lamentamos informarle que su solicitud (ID: %<application_id>s) ha sido archivada debido a que alcanzó el número máximo de intentos de revisión de documentos.

    Su solicitud actual no puede avanzar más en el proceso de revisión. Sin embargo, lo invitamos a presentar una nueva solicitud después del %<reapply_date_formatted>s.

    POR QUÉ SE ARCHIVAN LAS SOLICITUDES
    Las solicitudes pueden archivarse cuando no podemos verificar la elegibilidad después de múltiples intentos. Esto se debe típicamente a:
    * Documentación faltante o incompleta
    * Incapacidad para verificar la residencia

    FUTURAS SOLICITUDES
    Al enviar una nueva solicitud después del %<reapply_date_formatted>s, asegúrese de tener listo lo siguiente:
    * Prueba de residencia actual en Maryland
    * Cualquier documentación de discapacidad requerida para el programa

    Si tiene alguna pregunta sobre esta decisión o necesita ayuda con una futura solicitud, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name application_id reapply_date_formatted footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_max_rejections_reached_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
