# frozen_string_literal: true

# Seed File for "training_session_notifications_training_completed"
# (Suggest saving as db/seeds/email_templates/training_session_notifications_training_completed.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_completed', format: :text) do |template|
  template.subject = 'Training Session Completed'
  template.description = 'Sent to the user after their training session has been successfully completed and marked as such by the trainer.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<constituent_full_name>s,

    TRAINING SESSION COMPLETED
    Your training session with %<trainer_full_name>s has been completed successfully.

    Training Details:
    - Date Completed: %<completed_date_formatted>s
    - Trainer: %<trainer_full_name>s
    - Application ID: %<application_id>s

    If you have any questions about your training or need additional assistance, please contact your trainer:
    - Email: %<trainer_email>s
    - Phone: %<trainer_phone_formatted>s

    Thank you for participating in the training session. We hope it was helpful and informative!
    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name application_id completed_date_formatted
                          trainer_full_name trainer_email trainer_phone_formatted footer_text],
    'optional' => []
  }                     
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_completed (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
