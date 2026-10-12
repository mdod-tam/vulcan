# frozen_string_literal: true

class NeutralizeEvaluationConfirmationOutcomeCopy < ActiveRecord::Migration[8.0]
  class Template < ActiveRecord::Base
    self.table_name = 'email_templates'
  end

  TEMPLATE_NAME = 'evaluator_mailer_evaluation_submission_confirmation'
  TEXT_FORMAT = 1

  OLD_BODIES = {
    'en' => <<~TEXT,
      %<header_text>s

      Dear %<constituent_first_name>s

      We are writing to confirm that the Maryland Accessible Telecommunications Program has received your evaluation report.

      Based on the evaluation, the evaluator recommended the following accessible telecommunications product(s) as being useful for your communication needs:
      %<recommended_products_text_list>s

      This information is being provided for your records. Please note that the recommendation is based on the evaluator’s assessment.

      Please feel free to contact us with any questions or if you need further assistance.

      Sincerely,

      %<footer_text>s
    TEXT
    'es' => <<~TEXT
      %<header_text>s

      Estimado/a %<constituent_first_name>s:

      Le escribimos para confirmar que el Programa de Telecomunicaciones Accesibles de Maryland ha recibido su informe de evaluación.

      Según la evaluación, el evaluador recomendó los siguientes productos de telecomunicaciones accesibles como útiles para sus necesidades de comunicación:
      %<recommended_products_text_list>s

      Esta información se proporciona para sus registros. Tenga en cuenta que la recomendación se basa en la evaluación del evaluador.

      No dude en comunicarse con nosotros si tiene alguna pregunta o necesita más ayuda.

      Atentamente,

      %<footer_text>s
    TEXT
  }.freeze

  NEW_BODIES = {
    'en' => OLD_BODIES.fetch('en').sub(
      'Based on the evaluation, the evaluator recommended the following accessible telecommunications product(s) as being useful for your communication needs:',
      'The evaluation outcome and any product recommendations are:'
    ),
    'es' => OLD_BODIES.fetch('es').sub(
      'Según la evaluación, el evaluador recomendó los siguientes productos de telecomunicaciones accesibles como útiles para sus necesidades de comunicación:',
      'El resultado de la evaluación y las recomendaciones de productos, si las hay, son:'
    )
  }.freeze

  def up
    replace_stock_bodies(OLD_BODIES, NEW_BODIES)
  end

  def down
    replace_stock_bodies(NEW_BODIES, OLD_BODIES)
  end

  private

  def replace_stock_bodies(expected_bodies, replacement_bodies)
    expected_bodies.each do |locale, body|
      Template.where(name: TEMPLATE_NAME, format: TEXT_FORMAT, locale: locale, body: body).update_all(
        body: replacement_bodies.fetch(locale), previous_body: body, previous_subject: Arel.sql('subject'),
        version: Arel.sql('COALESCE(version, 0) + 1'), updated_at: Time.current
      )
    end
  end
end
