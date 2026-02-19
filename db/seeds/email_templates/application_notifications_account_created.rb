# frozen_string_literal: true

# Seed File for "application_notifications_account_created"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_account_created', format: :text, locale: 'en') do |template|
  template.subject = 'Your Maryland Accessible Telecommunications Account'
  template.description = 'Sent when an application is received and a constituent account is created, providing initial login details.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<constituent_first_name>s,

    Thank you for applying with Maryland Accessible Telecommunications. We are dedicated to providing accessible telecommunications solutions that help every Maryland resident stay connected. We have received your application, and an administrator has created an account for you in our system.

    Your new account lets you easily:
    - Check the status of your application
    - Upload additional proofs if needed
    - View your voucher code and other important updates

    You can access your application online using the following credentials:

    Email: %<constituent_email>s
    Temporary Password: %<temp_password>s

    For security reasons, you will be required to change your password when you first log in.

    Sign in here: %<sign_in_url>s

    If you prefer not to access your account online or encounter any issues, do not worry — we will continue to send you important updates and documents by mail.

    If you have any questions or need assistance, please contact our support team.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_first_name constituent_email temp_password sign_in_url footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_account_created (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
