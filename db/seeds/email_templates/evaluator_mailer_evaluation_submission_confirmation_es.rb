# frozen_string_literal: true

template = EmailTemplate.find_or_initialize_by(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'es')
template.update!(
  subject: 'Confirmación de Envío de Evaluación',
  description: 'Enviado a la persona solicitante después de que el evaluador envía una evaluación.',
  body: <<~TEXT,
    %<header_text>s

    Estimado/a %<constituent_first_name>s:

    Le escribimos para confirmar que el Programa de Telecomunicaciones Accesibles de Maryland ha recibido su informe de evaluación.

    El resultado de la evaluación y las recomendaciones de productos, si las hay, son:
    %<recommended_products_text_list>s

    Esta información se proporciona para sus registros. Tenga en cuenta que la recomendación se basa en la evaluación del evaluador.

    No dude en comunicarse con nosotros si tiene alguna pregunta o necesita más ayuda.

    Atentamente,

    %<footer_text>s
  TEXT
  variables: {
    'required' => %w[header_text constituent_first_name recommended_products_text_list footer_text],
    'optional' => []
  },
  version: 1
)
Rails.logger.debug 'Seeded evaluator_mailer_evaluation_submission_confirmation_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
