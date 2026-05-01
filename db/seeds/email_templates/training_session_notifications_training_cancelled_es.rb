# frozen_string_literal: true

# Seed File for "training_session_notifications_training_cancelled"
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'training_session_notifications_training_cancelled', format: :text, locale: 'es')
template.assign_attributes(
  subject: 'Sesión de capacitación cancelada',
  description: 'Enviado al usuario cuando se cancela su sesión de capacitación programada o asignación de capacitador.',
  body: <<~TEXT,
    %<header_text>s

    Hola %<constituent_full_name>s,

    %<cancellation_message>s

    Si tiene preguntas, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  variables: {
    'required' => %w[header_text constituent_full_name cancellation_message support_email footer_text],
    'optional' => %w[scheduled_date_time_formatted]
  },
  version: 2
)
template.save!
Rails.logger.debug 'Seeded training_session_notifications_training_cancelled_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
