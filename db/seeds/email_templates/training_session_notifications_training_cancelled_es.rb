# frozen_string_literal: true

# Seed File for "training_session_notifications_training_cancelled"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_cancelled', format: :text, locale: 'es') do |template|
  template.subject = 'Sesión de Entrenamiento Cancelada'
  template.description = 'Sent to the user when their scheduled training session has been cancelled.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    Su sesión de entrenamiento que estaba programada para el %<scheduled_date_time_formatted>s ha sido cancelada. Pedimos disculpas por cualquier inconveniente.

    Si tiene preguntas o desea reprogramar, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name scheduled_date_time_formatted support_email footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_cancelled_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
