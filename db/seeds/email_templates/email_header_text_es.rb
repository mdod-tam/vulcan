# frozen_string_literal: true

# Seed File for "email_header_text"
EmailTemplate.create_or_find_by!(name: 'email_header_text', format: :text, locale: 'es') do |template|
  template.subject = 'Texto de Encabezado de Correo Electrónico'
  template.description = 'Encabezado de texto estándar utilizado en todas las plantillas de correo electrónico'
  template.body = <<~TEXT
    %<title>s

    %<subtitle>s
  TEXT
  template.variables = {
    'required' => %w[title],
    'optional' => %w[subtitle]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded email_header_text_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
