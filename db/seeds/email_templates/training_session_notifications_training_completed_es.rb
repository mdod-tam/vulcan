# frozen_string_literal: true

# Seed File for "training_session_notifications_training_completed"
# (Suggest saving as db/seeds/email_templates/training_session_notifications_training_completed.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_completed', format: :text, locale: 'es') do |template|
  template.subject = 'Sesión de Entrenamiento Completada'
  template.description = 'Enviado al usuario después de que su sesión de capacitación se haya completado con éxito y el capacitador la haya marcado como tal.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    SESIÓN DE ENTRENAMIENTO COMPLETADA
    Su sesión de entrenamiento con %<trainer_full_name>s se ha completado exitosamente.

    Detalles del Entrenamiento:
    - Fecha de Finalización: %<completed_date_formatted>s
    - Entrenador: %<trainer_full_name>s
    - ID de Solicitud: %<application_id>s

    Si tiene alguna pregunta sobre su entrenamiento o necesita ayuda adicional, comuníquese con su entrenador:
    - Correo Electrónico: %<trainer_email>s
    - Teléfono: %<trainer_phone_formatted>s

    Gracias por participar en la sesión de entrenamiento. ¡Esperamos que haya sido útil e informativa!
    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name application_id completed_date_formatted
                     trainer_full_name trainer_email trainer_phone_formatted footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_completed_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
