# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_training_requested', format: :text, locale: 'en') do |template|
  template.subject = 'Training Requested for Application #%<application_id>s'
  template.description = 'Sent to administrators when a constituent requests training.'
  template.body = <<~TEXT
    %<header_text>s

    Hello %<admin_full_name>s,

    %<constituent_full_name>s requested training for Application #%<application_id>s on %<request_date_formatted>s.

    Review the request here:
    %<admin_application_url>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text admin_full_name constituent_full_name application_id request_date_formatted admin_application_url footer_text],
    'optional' => []
  }
  template.version = 1
end
