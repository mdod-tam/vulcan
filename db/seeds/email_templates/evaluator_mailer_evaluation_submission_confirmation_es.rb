# frozen_string_literal: true

# Seed File for "evaluator_mailer_evaluation_submission_confirmation"
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'es')
template.update!(
  subject: 'Confirmación de Envío de Evaluación',
  description: 'Enviado a la persona solicitante después de que el evaluador envía una evaluación.',
  body: <<~TEXT,
    %<header_text>s

    Hola %<constituent_first_name>s,

    %<status_box_text>s

    CONFIRMACIÓN DE ENVÍO DE EVALUACIÓN:
    - ID de Solicitud: %<application_id>s
    - Evaluador: %<evaluator_full_name>s
    - Fecha de Envío: %<submission_date_formatted>s

    Según la evaluación, el evaluador recomendó los siguientes productos:

    %<recommended_products_text_list>s

    Esta información se proporciona para sus registros.

    Si tiene alguna pregunta o necesita más ayuda, no dude en comunicarse.

    %<footer_text>s
  TEXT
  variables: {
    'required' => %w[header_text evaluator_full_name constituent_first_name application_id
                     submission_date_formatted recommended_products_text_list status_box_text footer_text],
    'optional' => []
  },
  version: 1
)
Rails.logger.debug 'Seeded evaluator_mailer_evaluation_submission_confirmation_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
