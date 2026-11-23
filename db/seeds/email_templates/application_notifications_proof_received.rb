# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_received', format: :text, locale: 'en') do |template|
  template.subject = 'Document Received'
  template.description = 'Sent when a piece of documentation submitted by the applicant has been received and is awaiting review.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    We received your %<proof_type_formatted>s document. We’ll let you know when we finish reviewing it.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name proof_type_formatted footer_text],
    'optional' => %w[organization_name]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_received (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
