# frozen_string_literal: true

# Seed File for "email_header_text"
EmailTemplate.create_or_find_by!(name: 'email_header_text', format: :text) do |template|
  template.subject = 'Email Header Text'
  template.description = 'Standard text header used in all email templates'
  template.body = <<~TEXT
    %<title>

    %<subtitle>
  TEXT
  template.variables = {
    'required' => %w[title],
    'optional' => %w[subtitle]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded email_header_text (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
