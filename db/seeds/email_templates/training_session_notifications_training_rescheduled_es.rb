# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_rescheduled', format: :text, locale: 'es') do |template|
  template.subject = 'Sesion de capacitacion reprogramada'
  template.description = 'Se envia a la persona cuando se reprograma su sesion de capacitacion.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    Su sesion de capacitacion con %<trainer_full_name>s ha sido reprogramada.

    Hora anterior:
    - Fecha: %<old_scheduled_date_formatted>s
    - Hora: %<old_scheduled_time_formatted>s

    Nueva hora:
    - Fecha: %<scheduled_date_formatted>s
    - Hora: %<scheduled_time_formatted>s

    Motivo: %<reschedule_reason>s

    Si tiene preguntas, comuniquese con su capacitador:
    - Correo electronico: %<trainer_email>s
    - Telefono: %<trainer_phone_formatted>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name trainer_full_name old_scheduled_date_formatted
                     old_scheduled_time_formatted scheduled_date_formatted scheduled_time_formatted
                     reschedule_reason trainer_email trainer_phone_formatted footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_rescheduled_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
