# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'user_mailer_password_reset', format: :text, locale: 'en') do |template|
  template.subject = 'Account Access Instructions'
  template.description = 'Sent when a user requests account access or a password reset. Contains a link to set a password.'
  template.body = <<~TEXT
    Hello,

    We received a request for account access or a password reset for %<user_email>s.

    Use this secure link to set your password and access your account:

    %<reset_url>s

    This link expires in 20 minutes. If you did not request account access, you can safely ignore this email.

    ---

    Have questions or need help? Reply to this email and our support team will help.
  TEXT
  template.variables = {
    'required' => %w[user_email reset_url],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded user_mailer_password_reset (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
