# frozen_string_literal: true

EmailTemplate.find_or_create_by!(name: 'training_session_notifications_training_completed', format: :text, locale: 'en') do |template|
  template.subject = 'Your training report is ready'
  template.description = 'Sent after a trainer submits a completed training report.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<recipient_full_name>s,

    Your training with %<trainer_full_name>s for %<constituent_full_name>s was completed on %<completed_date_formatted>s at %<completed_time_formatted>s.

    Sign in to read the written session summary and find guidance for the product used during training:
    %<report_url>s

    The summary keeps the language in which your trainer wrote it.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text recipient_full_name constituent_full_name trainer_full_name
                     completed_date_formatted completed_time_formatted report_url footer_text],
    'optional' => []
  }
  template.version = 1
end
