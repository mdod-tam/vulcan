# frozen_string_literal: true

# Seed File for "training_session_notifications_trainer_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_trainer_assigned', format: :text, locale: 'es') do |template|
  template.subject = 'Entrenador Asignado'
  template.description = 'Sent to the user when a trainer has been assigned to them.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_full_name>s,

    %<status_box_text>s

    ENTRENADOR ASIGNADO
    Se le ha asignado un entrenador para capacitarle en el uso de productos de telecomunicaciones.

    Detalles del Entrenador:
    - Nombre: %<trainer_full_name>s
    - Correo Electrónico: %<trainer_email>s
    - Teléfono: %<trainer_phone_formatted>s

    Sus Detalles:
    - Dirección: %<constituent_address_formatted>s
    - Teléfono: %<constituent_phone_formatted>s
    - Correo Electrónico: %<constituent_email>s

    Horario de la Sesión de Entrenamiento:
    %<training_session_schedule_text>s

    Notas Adicionales:
    %<constituent_disabilities_text_list>s

    Por favor comuníquese con su entrenador para discutir sus necesidades de entrenamiento y programar una sesión.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name status_box_text trainer_full_name trainer_email
                     trainer_phone_formatted training_session_schedule_text constituent_address_formatted
                     constituent_phone_formatted constituent_email constituent_disabilities_text_list footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_trainer_assigned_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
