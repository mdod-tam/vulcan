# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'application_notifications_registration_confirmation', format: :text, locale: 'en') do |template|
  template.subject = 'Welcome to the Maryland Accessible Telecommunications Program'
  template.description = 'Sent to a user immediately after they register an account, outlining program and next steps.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_full_name>s,

    Your MAT account is ready. Sign in to start your application.

    Have your photo ID, proof of your Maryland address, and your certifying professional’s contact details ready. MAT may also ask for proof of household income.

    For help, email %<support_email>s or call 410-697-9700.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_full_name footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_registration_confirmation (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
