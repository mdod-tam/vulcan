# frozen_string_literal: true

# Seed File for "evaluator_mailer_new_evaluation_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'evaluator_mailer_new_evaluation_assigned', format: :text, locale: 'es') do |template|
  template.subject = 'Nueva Evaluación Asignada'
  template.description = 'Sent to an evaluator when a new constituent evaluation has been assigned to them.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<evaluator_full_name>s,

    %<status_box_text>s

    DETALLES DEL SOLICITANTE:
    - Nombre: %<constituent_full_name>s
    - Dirección: %<constituent_address_formatted>s
    - Teléfono: %<constituent_phone_formatted>s
    - Correo Electrónico: %<constituent_email>s

    DISCAPACIDADES:
    %<constituent_disabilities_text_list>s

    Puede ver y actualizar la evaluación aquí:
    %<evaluators_evaluation_url>s

    Por favor, comience el proceso de evaluación comunicándose con el solicitante para programar una evaluación.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text evaluator_full_name status_box_text constituent_full_name
                     constituent_address_formatted constituent_phone_formatted constituent_email
                     constituent_disabilities_text_list evaluators_evaluation_url footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded evaluator_mailer_new_evaluation_assigned_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
