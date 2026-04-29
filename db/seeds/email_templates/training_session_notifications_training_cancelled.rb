# frozen_string_literal: true

# Seed File for "training_session_notifications_training_cancelled"
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'training_session_notifications_training_cancelled', format: :text, locale: 'en')
template.assign_attributes(
  subject: 'Training Session Cancelled',
  description: 'Sent to the user when their scheduled training session or trainer assignment has been cancelled.',
  body: <<~TEXT,
    %<header_text>s

    Hello %<constituent_full_name>s,

    %<cancellation_message>s

    If you have questions, please contact our team at %<support_email>s or call (410) 767-6960.

    %<footer_text>s
  TEXT
  variables: {
    'required' => %w[header_text constituent_full_name cancellation_message support_email footer_text],
    'optional' => %w[scheduled_date_time_formatted]
  },
  version: 2
)
template.save!
Rails.logger.debug 'Seeded training_session_notifications_training_cancelled (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
