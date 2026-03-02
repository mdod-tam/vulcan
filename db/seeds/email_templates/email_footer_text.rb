# frozen_string_literal: true

# Seed File for "email_footer_text"
EmailTemplate.create_or_find_by!(name: 'email_footer_text', format: :text, locale: 'en') do |template|
  template.subject = 'Email Footer Text'
  template.description = 'Standard text footer used in all email templates'
  template.body = <<~TEXT
    --
    %<organization_name>
    Email: %<contact_email>
    Website: %<website_url>

    %<show_automated_message>
    This is an automated message. Please do not reply directly to this email.
  TEXT
  template.variables = {
    'required' => %w[contact_email website_url],
    'optional' => %w[show_automated_message organization_name]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded email_footer_text (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
