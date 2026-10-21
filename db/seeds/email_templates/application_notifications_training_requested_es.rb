# frozen_string_literal: true

EmailTemplate.find_or_create_by!(name: 'application_notifications_training_requested', format: :text, locale: 'es') do |template|
  template.subject = 'Capacitación solicitada para la solicitud #%<application_id>s'
  template.description = 'Se envía al capacitador asignado cuando la persona solicita capacitación.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<admin_full_name>s:

    %<constituent_full_name>s solicitó capacitación para la solicitud #%<application_id>s el %<request_date_formatted>s.

    Enlace a la solicitud de capacitación:
    %<admin_application_url>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text admin_full_name constituent_full_name application_id request_date_formatted admin_application_url footer_text],
    'optional' => []
  }
  template.version = 1
end
