# frozen_string_literal: true

# Seed File for "evaluator_mailer_new_evaluation_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'evaluator_mailer_new_evaluation_assigned', format: :text, locale: 'en') do |template|
  template.subject = 'New Evaluation Assigned'
  template.description = 'Sent to an evaluator when a new constituent evaluation has been assigned to them.'
  template.body = <<~TEXT
    %<header_text>s

    Hi %<evaluator_full_name>s,

    %<status_box_text>s

    CONSTITUENT DETAILS:
    - Name: %<constituent_full_name>s
    - Address: %<constituent_address_formatted>s
    - Phone: %<constituent_phone_formatted>s
    - Email: %<constituent_email>s

    DISABILITIES:
    %<constituent_disabilities_text_list>s

    You can view and update the evaluation here:
    %<evaluators_evaluation_url>s

    Please begin the evaluation process by contacting the constituent to schedule an assessment.

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
Rails.logger.debug 'Seeded evaluator_mailer_new_evaluation_assigned (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
