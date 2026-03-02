# frozen_string_literal: true

# Seed File for "application_notifications_application_submitted"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_application_submitted', format: :text, locale: 'es') do |template|
  template.subject = 'Su Solicitud Ha Sido Enviada'
  template.description = 'Sent when an application is submitted.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    Gracias por enviar su solicitud. La revisaremos lo antes posible.

    ID de Solicitud: %<application_id>s
    Fecha de Envío: %<submission_date_formatted>s

    Le notificaremos de cualquier actualización de estado o si necesitamos documentación adicional.

    %<sign_in_url>s

    Si tiene alguna pregunta sobre su solicitud, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name application_id submission_date_formatted footer_text support_email],
    'optional' => %w[sign_in_url]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_application_submitted_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
