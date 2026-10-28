# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_rescheduled', format: :text, locale: 'es') do |template|
  template.subject = 'Sesión de capacitación reprogramada'
  template.description = 'Se envía a la persona cuando se reprograma su sesión de capacitación.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    Su sesión de capacitación con %<trainer_full_name>s ha sido reprogramada.

    Hora anterior:
    - Fecha: %<old_scheduled_date_formatted>s
    - Hora: %<old_scheduled_time_formatted>s

    Nueva hora:
    - Fecha: %<scheduled_date_formatted>s
    - Hora: %<scheduled_time_formatted>s


    Si tiene preguntas, comuníquese con su capacitador:
    - Correo electrónico: %<trainer_email>s
    - Teléfono: %<trainer_phone_formatted>s

    Lugar o instrucciones para reunirse: %<scheduled_location>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name trainer_full_name old_scheduled_date_formatted
                     old_scheduled_time_formatted scheduled_date_formatted scheduled_time_formatted
                     trainer_email trainer_phone_formatted footer_text],
    'optional' => %w[scheduled_location]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_rescheduled_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
