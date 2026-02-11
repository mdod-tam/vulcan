# frozen_string_literal: true

# Seed File for "user_mailer_password_reset"
# (Suggest saving as db/seeds/email_templates/user_mailer_password_reset.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'user_mailer_password_reset', format: :text) do |template|
  template.subject = 'Password Reset Instructions'
  template.description = 'Sent when a user requests to reset their password. Contains a link to set a new password.'
  template.body = <<~TEXT
    Hey there,

    Can't remember your password for %<user_email>s? That's OK, it happens. Just click the link below to set a new one.

    %<reset_url>s

    If you did not request a password reset you can safely ignore this email, it expires in 20 minutes. Only someone with access to this email account can reset your password.

    ---

    Have questions or need help? Just reply to this email and our support team will help you sort it out.
  TEXT
  template.variables = {
    'required' => %w[user_email reset_url],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded user_mailer_password_reset (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
