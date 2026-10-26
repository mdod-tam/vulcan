# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'training_session_notifications_trainer_reassigned', format: :text, locale: 'es') do |template|
  template.subject = 'Capacitación reasignada a usted'
  template.description = 'Enviado a un capacitador cuando se le ha transferido una capacitación abierta.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<trainer_full_name>s,

    Se le ha transferido la capacitación abierta de %<constituent_full_name>s. La cita ya programada no ha cambiado: %<training_session_schedule_text>s. Confirme los arreglos con la persona.

    Detalles de la persona:
    - Nombre: %<constituent_full_name>s
    - Correo electrónico: %<constituent_email>s
    - Teléfono: %<constituent_phone_formatted>s
    - Dirección: %<constituent_address_formatted>s
    - Discapacidades: %<constituent_disabilities_text_list>s

    Preferencias de comunicación:
    - Idioma preferido: %<constituent_language>s
    - Método de contacto preferido: %<constituent_contact_method>s
    - Modalidad de comunicación: %<constituent_communication_modality>s

    ID de solicitud: %<application_id>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text trainer_full_name constituent_full_name constituent_email
                     constituent_phone_formatted constituent_address_formatted constituent_disabilities_text_list
                     constituent_language constituent_contact_method constituent_communication_modality
                     application_id training_session_schedule_text footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_trainer_reassigned_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
