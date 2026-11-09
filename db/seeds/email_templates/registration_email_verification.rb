# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'registration_email_verification', format: :text, locale: 'en') do |template|
  template.subject = 'Confirm your email to continue with MAT'
  template.description = 'Confirms access to an email address before registration. This link does not sign in an existing account.'
  template.body = <<~TEXT
    Hello,

    Someone requested to continue with MAT using this email address.

    Confirm your email and continue:
    %<verification_url>s

    Finish creating your account before this link expires: %<expires_at>s.
    Confirming your email does not sign you in to an existing account.

    If you did not request this, ignore this email. Your account has not been changed.
  TEXT
  template.variables = { 'required' => %w[verification_url expires_at], 'optional' => [] }
  template.version = 1
end
