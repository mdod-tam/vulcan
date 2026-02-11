# frozen_string_literal: true

# Seed File for "training_session_notifications_trainer_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_trainer_assigned', format: :text) do |template|
  template.subject = 'Trainer Assigned'
  template.description = 'Sent to the user when a trainer has been assigned to them.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<constituent_full_name>s,

    %<status_box_text>s

    TRAINER ASSIGNED
    A trainer has been assigned to you for your training session.

    Trainer Details:
    - Name: %<trainer_full_name>s
    - Email: %<trainer_email>s
    - Phone: %<trainer_phone_formatted>s

    Your Details:
    - Address: %<constituent_address_formatted>s
    - Phone: %<constituent_phone_formatted>s
    - Email: %<constituent_email>s

    Training Session Schedule:
    %<training_session_schedule_text>s

    Additional Notes:
    %<constituent_disabilities_text_list>s

    Please reach out to your trainer to discuss your training needs and schedule a session.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name status_box_text trainer_full_name trainer_email
                          trainer_phone_formatted training_session_schedule_text constituent_address_formatted
                          constituent_phone_formatted constituent_email constituent_disabilities_text_list footer_text],
    'optional' => []
  }                     
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_trainer_assigned (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
