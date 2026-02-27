# frozen_string_literal: true

# Seed File for "evaluator_mailer_evaluation_submission_confirmation"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'en') do |template|
  template.subject = 'Evaluation Submission Confirmation'
  template.description = 'Sent to the evaluator after they have submitted their evaluation.'
  template.body = <<~TEXT
    %<header_text>s

    Hi %<constituent_first_name>s,

    %<status_box_text>s

    EVALUATION SUBMISSION CONFIRMATION:
    - Application ID: %<application_id>s
    - Evaluator: %<evaluator_full_name>s
    - Submission Date: %<submission_date_formatted>s

    Thank you for your prompt submission. Your evaluation is now under review.

    If you have any questions or need further assistance, please feel free to reach out.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text evaluator_full_name constituent_first_name application_id
                     submission_date_formatted status_box_text footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded evaluator_mailer_evaluation_submission_confirmation (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
