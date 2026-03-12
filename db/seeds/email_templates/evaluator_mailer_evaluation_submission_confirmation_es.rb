# frozen_string_literal: true

# Seed File for "evaluator_mailer_evaluation_submission_confirmation"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'es') do |template|
  template.subject = 'Confirmación de Envío de Evaluación'
  template.description = 'Enviado al evaluador después de haber enviado su evaluación.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<constituent_first_name>s,

    %<status_box_text>s

    CONFIRMACIÓN DE ENVÍO DE EVALUACIÓN:
    - ID de Solicitud: %<application_id>s
    - Evaluador: %<evaluator_full_name>s
    - Fecha de Envío: %<submission_date_formatted>s

    Gracias por su pronto envío. Su evaluación está ahora en revisión.

    Si tiene alguna pregunta o necesita más ayuda, no dude en comunicarse.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text evaluator_full_name constituent_first_name application_id
                     submission_date_formatted status_box_text footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded evaluator_mailer_evaluation_submission_confirmation_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
