# frozen_string_literal: true

# Seed File for "training_session_notifications_trainer_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_trainer_assigned', format: :text, locale: 'es') do |template|
  template.subject = 'Entrenador Asignado'
  template.description = 'Enviado al usuario cuando se le ha asignado un capacitador.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    ENTRENADOR ASIGNADO
    Se le ha asignado un entrenador para capacitarle en el uso de productos de telecomunicaciones.

    Detalles del Entrenador:
    - Nombre: %<trainer_full_name>s
    - Correo Electrónico: %<trainer_email>s
    - Teléfono: %<trainer_phone_formatted>s

    Horario de la Sesión de Entrenamiento:
    %<training_session_schedule_text>s

    Por favor comuníquese con su entrenador para discutir sus necesidades de entrenamiento y programar una sesión.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name trainer_full_name trainer_email
                     trainer_phone_formatted training_session_schedule_text footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_trainer_assigned_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
