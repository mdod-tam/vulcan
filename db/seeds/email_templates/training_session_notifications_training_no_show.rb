# frozen_string_literal: true

# Seed File for "training_session_notifications_training_no_show"
# (Suggest saving as db/seeds/email_templates/training_session_notifications_training_no_show.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'training_session_notifications_training_no_show', format: :text) do |template|
  template.subject = 'Training Session No Show'
  template.description = 'Sent to the user when they have not shown up for their scheduled training session.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<constituent_full_name>s,

    We noticed you did not attend your training session scheduled for %<scheduled_date_time_formatted>s. If you need to reschedule, please contact your trainer at %<trainer_email>s or our support team at %<support_email>s.

    Thank you,
    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_full_name scheduled_date_time_formatted trainer_email
                          support_email footer_text],
    'optional' => []
  }                     
  template.version = 1
end
Rails.logger.debug 'Seeded training_session_notifications_training_no_show (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
