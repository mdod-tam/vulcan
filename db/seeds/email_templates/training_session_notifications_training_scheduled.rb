# frozen_string_literal: true

# Seed File for "training_session_notifications_training_scheduled"
# (Suggest saving as db/seeds/email_templates/training_session_notifications_training_scheduled.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_scheduled', format: :text, locale: 'en') do |template|
  template.subject = 'Training Session Scheduled'
  template.description = 'Sent to the user when their training session has been scheduled.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<constituent_full_name>s,

    TRAINING SESSION SCHEDULED
    Your training session has been scheduled with %<trainer_full_name>s.

    Training Details:
    - Date: %<scheduled_date_formatted>s
    - Time: %<scheduled_time_formatted>s
    - Trainer: %<trainer_full_name>s

    If you need to reschedule or have any questions, please contact your trainer directly:
    - Email: %<trainer_email>s
    - Phone: %<trainer_phone_formatted>s

    We look forward to helping you with your training session!
    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name scheduled_date_formatted scheduled_time_formatted
                          trainer_full_name trainer_email trainer_phone_formatted footer_text],
    'optional' => []
  }                    
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_scheduled (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
