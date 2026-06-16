# frozen_string_literal: true

# Seed File for "evaluator_mailer_new_evaluation_assigned"
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'evaluator_mailer_new_evaluation_assigned', format: :text, locale: 'en')
template.update!(
  subject: 'New Evaluation Assigned',
  description: 'Sent to an evaluator when a new constituent evaluation has been assigned to them.',
  body: <<~TEXT,
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

    Evaluator evaluation link:
    %<evaluators_evaluation_url>s

    Please begin the evaluation process by contacting the constituent to schedule an assessment.

    %<footer_text>s
  TEXT
  variables: {
    'required' => %w[header_text evaluator_full_name status_box_text constituent_full_name
                     constituent_address_formatted constituent_phone_formatted constituent_email
                     constituent_contact_method constituent_preferred_language
                     constituent_communication_modality constituent_delivery_preference
                     constituent_disabilities_text_list evaluators_evaluation_url footer_text],
    'optional' => []
  },
  version: 1
)
Rails.logger.debug 'Seeded evaluator_mailer_new_evaluation_assigned (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
