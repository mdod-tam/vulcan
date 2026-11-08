# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'registration_email_verification', format: :text, locale: 'en') do |template|
  template.subject = 'Confirm your email to continue with MAT'
  template.description = 'Confirms access to an email address before registration. This link does not sign in an existing account.'
  template.body = <<~TEXT
    Hello,

    Someone requested to continue with MAT using this email address.

    Confirm your email and continue:
    %<verification_url>s

    This link expires 20 minutes after it was requested. Confirming your email does not sign you in to an existing account.

    If you did not request this, ignore this email. Your account has not been changed.
  TEXT
  template.variables = { 'required' => %w[verification_url], 'optional' => [] }
  template.version = 1
end
