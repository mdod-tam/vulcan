# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'contact_change_verification', format: :text, locale: 'en') do |template|
  template.subject = 'Confirm your account contact'
  template.description = 'Confirms ownership of an old or proposed account email.'
  template.body = <<~TEXT
    Confirm this account contact change using the link below. The link expires twenty minutes after the request was made.

    %<confirmation_url>s

    If you did not request this change, contact %<support_email>s. Your existing contact stays active until all required confirmations are complete.
  TEXT
  template.variables = { 'required' => %w[confirmation_url support_email], 'optional' => [] }
  template.version = 1
end
