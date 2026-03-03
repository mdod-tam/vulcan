# frozen_string_literal: true

# Seed File for "training_session_notifications_training_scheduled"
# (Suggest saving as db/seeds/email_templates/training_session_notifications_training_scheduled.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_scheduled', format: :text, locale: 'es') do |template|
  template.subject = 'Sesión de Entrenamiento Programada'
  template.description = 'Enviado al usuario cuando se ha programado su sesión de capacitación.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    SESIÓN DE ENTRENAMIENTO PROGRAMADA
    Su sesión de entrenamiento ha sido programada con %<trainer_full_name>s.

    Detalles del Entrenamiento:
    - Fecha: %<scheduled_date_formatted>s
    - Hora: %<scheduled_time_formatted>s
    - Entrenador: %<trainer_full_name>s

    Si necesita reprogramar o tiene alguna pregunta, comuníquese directamente con su entrenador:
    - Correo Electrónico: %<trainer_email>s
    - Teléfono: %<trainer_phone_formatted>s

    ¡Esperamos ayudarle con su sesión de entrenamiento!
    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name scheduled_date_formatted scheduled_time_formatted
                     trainer_full_name trainer_email trainer_phone_formatted footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_scheduled_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
