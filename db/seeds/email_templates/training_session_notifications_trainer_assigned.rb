# frozen_string_literal: true

# Seed File for "training_session_notifications_trainer_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_trainer_assigned', format: :text, locale: 'en') do |template|
  template.subject = 'New Training Assignment'
  template.description = 'Sent to a trainer when a training session has been assigned to them.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<trainer_full_name>s,

    You've been assigned as the trainer for %<constituent_full_name>s. Please contact them to schedule your first session. More information is below.

    Constituent details:
    - Name: %<constituent_full_name>s
    - Email: %<constituent_email>s
    - Phone: %<constituent_phone_formatted>s
    - Address: %<constituent_address_formatted>s
    - Disabilities: %<constituent_disabilities_text_list>s

    Communication preferences:
    - Preferred language: %<constituent_language>s
    - Preferred contact method: %<constituent_contact_method>s
    - Communication modality: %<constituent_communication_modality>s

    Application ID: %<application_id>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text trainer_full_name constituent_full_name constituent_email
                     constituent_phone_formatted constituent_address_formatted constituent_disabilities_text_list
                     constituent_language constituent_contact_method constituent_communication_modality
                     application_id footer_text],
    'optional' => %w[training_session_schedule_text]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_trainer_assigned (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
