# frozen_string_literal: true

# Seed File for "user_mailer_email_verification.rb"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'user_mailer_email_verification', format: :text, locale: 'en') do |template|
  template.subject = 'Please confirm your email address'
  template.description = 'Sent to a user to verify their email address by clicking a confirmation link.'
  template.body = <<~TEXT
    Hey there,

    This is to confirm that %<user_email>s is the email you've chosen use on your account. If you ever lose your password, that's where we'll email a reset link.

    *You must click the link below to confirm that you received this email.*

    %<verification_url>s

    ---

    Have questions or need help? Just reply to this email and our team will help you sort it out.
  TEXT
  template.variables = {
    'required' => %w[user_email verification_url],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded user_notifications_email_confirmation (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
