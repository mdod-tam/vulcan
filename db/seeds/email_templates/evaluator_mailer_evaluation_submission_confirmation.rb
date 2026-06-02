# frozen_string_literal: true

# Seed File for "evaluator_mailer_evaluation_submission_confirmation"
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'en')
template.update!(
  subject: 'Evaluation Submission Confirmation',
  description: 'Sent to the constituent after the evaluator submits an evaluation.',
  body: <<~TEXT,
    %<header_text>s

    Hi %<constituent_first_name>s,

    %<status_box_text>s

    EVALUATION SUBMISSION CONFIRMATION:
    - Application ID: %<application_id>s
    - Evaluator: %<evaluator_full_name>s
    - Submission Date: %<submission_date_formatted>s

    Based on the evaluation, the evaluator recommended the following product(s):

    %<recommended_products_text_list>s

    This information is being provided for your records.

    If you have any questions or need further assistance, please feel free to reach out.

    %<footer_text>s
  TEXT
  variables: {
    'required' => %w[header_text evaluator_full_name constituent_first_name application_id
                     submission_date_formatted recommended_products_text_list status_box_text footer_text],
    'optional' => []
  },
  version: 1
)
Rails.logger.debug 'Seeded evaluator_mailer_evaluation_submission_confirmation (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
