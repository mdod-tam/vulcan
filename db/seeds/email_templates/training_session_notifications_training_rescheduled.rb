# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_rescheduled', format: :text, locale: 'en') do |template|
  template.subject = 'Training Session Rescheduled'
  template.description = 'Sent to the constituent when their training session has been rescheduled.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<constituent_full_name>s,

    Your training session with %<trainer_full_name>s has been rescheduled.

    Previous time:
    - Date: %<old_scheduled_date_formatted>s
    - Time: %<old_scheduled_time_formatted>s

    New time:
    - Date: %<scheduled_date_formatted>s
    - Time: %<scheduled_time_formatted>s

    Reason: %<reschedule_reason>s

    If you have questions, please contact your trainer:
    - Email: %<trainer_email>s
    - Phone: %<trainer_phone_formatted>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name trainer_full_name old_scheduled_date_formatted
                     old_scheduled_time_formatted scheduled_date_formatted scheduled_time_formatted
                     reschedule_reason trainer_email trainer_phone_formatted footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_rescheduled (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
