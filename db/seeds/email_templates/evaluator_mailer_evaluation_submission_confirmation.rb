# frozen_string_literal: true

# Seed File for "evaluator_mailer_evaluation_submission_confirmation"
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'en')
template.update!(
  subject: 'Evaluation Submission Confirmation',
  description: 'Sent to the constituent after the evaluator submits an evaluation.',
  body: <<~TEXT,
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
  variables: {
    'required' => %w[header_text constituent_first_name recommended_products_text_list footer_text],
    'optional' => []
  },
  version: 1
)
Rails.logger.debug 'Seeded evaluator_mailer_evaluation_submission_confirmation (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
