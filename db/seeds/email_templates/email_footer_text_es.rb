# frozen_string_literal: true

# Seed File for "email_footer_text"
EmailTemplate.create_or_find_by!(name: 'email_footer_text', format: :text, locale: 'es') do |template|
  template.subject = 'Texto del Pie de Página del Correo Electrónico'
  template.description = 'Standard text footer used in all email templates'
  template.body = <<~TEXT
    --
    %<organization_name>s
    Correo Electrónico: %<contact_email>s
    Sitio Web: %<website_url>s

    %<show_automated_message>s
    Este es un mensaje automático. Por favor, no responda directamente a este correo electrónico.
  TEXT
  template.variables = {
    'required' => %w[contact_email website_url],
    'optional' => %w[show_automated_message organization_name]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded email_footer_text_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
