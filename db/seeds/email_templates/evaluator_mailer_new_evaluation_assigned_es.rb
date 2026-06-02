# frozen_string_literal: true

# Seed File for "evaluator_mailer_new_evaluation_assigned"
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'evaluator_mailer_new_evaluation_assigned', format: :text, locale: 'es')
template.update!(
  subject: 'Nueva Evaluación Asignada',
  description: 'Enviado a un evaluador cuando se le ha asignado una nueva evaluación de un constituyente.',
  body: <<~TEXT,
    %<header_text>s

    Hola %<evaluator_full_name>s,

    %<status_box_text>s

    DETALLES DEL SOLICITANTE:
    - Nombre: %<constituent_full_name>s
    - Dirección: %<constituent_address_formatted>s
    - Teléfono: %<constituent_phone_formatted>s
    - Correo Electrónico: %<constituent_email>s
    - Método de Contacto: %<constituent_contact_method>s
    - Idioma Preferido: %<constituent_preferred_language>s
    - Modalidad de Comunicación: %<constituent_communication_modality>s
    - Preferencia de Entrega: %<constituent_delivery_preference>s

    DISCAPACIDADES:
    %<constituent_disabilities_text_list>s

    Puede ver y actualizar la evaluación aquí:
    %<evaluators_evaluation_url>s

    Por favor, comience el proceso de evaluación comunicándose con el solicitante para programar una evaluación.

    %<footer_text>s
  TEXT
  variables: {
    'required' => %w[header_text evaluator_full_name status_box_text constituent_full_name
                     constituent_address_formatted constituent_phone_formatted constituent_email
                     constituent_contact_method constituent_preferred_language
                     constituent_communication_modality constituent_delivery_preference
                     constituent_disabilities_text_list evaluators_evaluation_url footer_text],
    'optional' => []
  },
  version: 1
)
Rails.logger.debug 'Seeded evaluator_mailer_new_evaluation_assigned_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
