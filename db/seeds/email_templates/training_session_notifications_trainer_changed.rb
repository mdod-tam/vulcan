# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'training_session_notifications_trainer_changed', format: :text, locale: 'en') do |template|
  template.subject = 'Your Trainer Has Changed'
  template.description = 'Sent to the constituent when open training is transferred to another trainer.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<constituent_full_name>s,

    Your training is now with a different trainer. Any appointment already scheduled has not changed.

    Your trainer:
    - Name: %<trainer_full_name>s
    - Email: %<trainer_email>s
    - Phone: %<trainer_phone_formatted>s

    Appointment: %<training_session_schedule_text>s
    Location: %<scheduled_location>s

    If you have questions, contact our team at %<support_email>s or call (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name trainer_full_name trainer_email trainer_phone_formatted
                     training_session_schedule_text scheduled_location support_email footer_text],
    'optional' => %w[application_id]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_trainer_changed (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
