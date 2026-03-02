# frozen_string_literal: true

# Seed File for "training_session_notifications_training_no_show"
# (Suggest saving as db/seeds/email_templates/training_session_notifications_training_no_show.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_no_show', format: :text, locale: 'es') do |template|
  template.subject = 'Ausencia en Sesión de Entrenamiento'
  template.description = 'Sent to the user when they have not shown up for their scheduled training session.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    Notamos que no asistió a su sesión de entrenamiento programada para el %<scheduled_date_time_formatted>s. Si necesita reprogramar, comuníquese con su entrenador al %<trainer_email>s o con nuestro equipo de soporte a %<support_email>s.

    Gracias,
    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name scheduled_date_time_formatted trainer_email
                     support_email footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_no_show_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
