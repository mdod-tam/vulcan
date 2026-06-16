# frozen_string_literal: true

class UpdateEvaluatorEmailTemplatesForWorkflowParity < ActiveRecord::Migration[8.0]
  ASSIGNMENT_VARIABLES = {
    'required' => %w[
      header_text evaluator_full_name status_box_text constituent_full_name
      constituent_address_formatted constituent_phone_formatted constituent_email
      constituent_contact_method constituent_preferred_language
      constituent_communication_modality constituent_delivery_preference
      constituent_disabilities_text_list evaluators_evaluation_url footer_text
    ],
    'optional' => []
  }.freeze

  SUBMISSION_VARIABLES = {
    'required' => %w[
      header_text constituent_first_name recommended_products_text_list footer_text
    ],
    'optional' => []
  }.freeze

  ASSIGNMENT_BODY = <<~TEXT
    %<header_text>s

    Hi %<evaluator_full_name>s,

    %<status_box_text>s

    CONSTITUENT DETAILS:
    - Name: %<constituent_full_name>s
    - Address: %<constituent_address_formatted>s
    - Phone: %<constituent_phone_formatted>s
    - Email: %<constituent_email>s
    - Contact Method: %<constituent_contact_method>s
    - Preferred Language: %<constituent_preferred_language>s
    - Communication Modality: %<constituent_communication_modality>s
    - Delivery Preference: %<constituent_delivery_preference>s

    DISABILITIES:
    %<constituent_disabilities_text_list>s

    You can view and update the evaluation here:
    %<evaluators_evaluation_url>s

    Please begin the evaluation process by contacting the constituent to schedule an assessment.

    %<footer_text>s
  TEXT

  SUBMISSION_BODIES = {
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

  def up
    upsert_assignment_templates
    upsert_submission_templates
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def upsert_assignment_templates
    template = EmailTemplate.find_or_initialize_by(
      name: 'evaluator_mailer_new_evaluation_assigned',
      format: :text,
      locale: 'en'
    )

    template.update!(
      subject: 'New Evaluation Assigned',
      description: 'Sent to an evaluator when a new constituent evaluation has been assigned to them.',
      body: ASSIGNMENT_BODY,
      variables: ASSIGNMENT_VARIABLES,
      version: 1
    )
  end

  def upsert_submission_templates
    SUBMISSION_BODIES.each do |locale, body|
      template = EmailTemplate.find_or_initialize_by(
        name: 'evaluator_mailer_evaluation_submission_confirmation',
        format: :text,
        locale: locale
      )

      template.update!(
        subject: locale == 'es' ? 'Confirmación de Envío de Evaluación' : 'Evaluation Submission Confirmation',
        description: submission_description(locale),
        body: body,
        variables: SUBMISSION_VARIABLES,
        version: 1
      )
    end
  end

  def submission_description(locale)
    if locale == 'es'
      'Enviado a la persona solicitante después de que el evaluador envía una evaluación.'
    else
      'Sent to the constituent after the evaluator submits an evaluation.'
    end
  end
end
