# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'training_session_notifications_trainer_changed', format: :text, locale: 'es') do |template|
  template.subject = 'Su capacitador ha cambiado'
  template.description = 'Enviado a la persona solicitante cuando su capacitación abierta se transfiere a otro capacitador.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    Su capacitación ahora está con otro capacitador. La cita ya programada no ha cambiado.

    Su capacitador:
    - Nombre: %<trainer_full_name>s
    - Correo electrónico: %<trainer_email>s
    - Teléfono: %<trainer_phone_formatted>s

    Cita: %<training_session_schedule_text>s
    Lugar: %<scheduled_location>s

    Si tiene preguntas, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name trainer_full_name trainer_email trainer_phone_formatted
                     training_session_schedule_text scheduled_location support_email footer_text],
    'optional' => %w[application_id]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_trainer_changed_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
